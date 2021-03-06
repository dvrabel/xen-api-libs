(*
 * Copyright (C) 2006-2010 Citrix Systems Inc.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published
 * by the Free Software Foundation; version 2.1 only. with the special
 * exception on linking described in file LICENSE.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *)
(* A very simple HTTP client *)

open Stringext

module D = Debug.Debugger(struct let name="http" end)
open D

exception Connection_reset

(** Thrown when no data is received from the remote HTTP server. This could happen if
    (eg) an stunnel accepted the connection but xapi refused the forward causing stunnel
    to immediately close. *)
exception Empty_response_from_server

(** Thrown when we get a non-HTTP response *)
exception Http_request_rejected of string

(** Thrown when we get a specific HTTP failure *)
exception Http_error of string * string

(** Thrown when we fail to parse a particular part of the HTTP message *)
exception Parse_error of string

let http_rpc_send_query fd request =
	try
		Unixext.really_write_string fd (Http.Request.to_wire_string request)
	with
	| Unix.Unix_error(Unix.ECONNRESET, _, _) -> raise Connection_reset

(* Internal exception thrown when reading a newline-terminated HTTP header when the 
   connection is closed *)
exception Http_header_truncated of string

(* Tediously read an HTTP header byte-by-byte. At some point we need to add buffering
   but we'll need to encapsulate our file descriptor into more of a channel-like object
   to make that work. *)
let input_line_fd (fd: Unix.file_descr) = 
	let buf = Buffer.create 20 in
	let finished = ref false in
	try
		while not(!finished) do
			let buffer = " " in
			let read = Unix.read fd buffer 0 1 in
			if read = 1 then begin
				if buffer = "\n"
				then finished := true
				else Buffer.add_char buf buffer.[0]
			end else begin
				if Buffer.contents buf = ""
				then finished := true
				else raise (Http_header_truncated (Buffer.contents buf));
			end
		done;
		Buffer.contents buf
	with
	| Unix.Unix_error(Unix.ECONNRESET, _, _) -> raise Connection_reset

let response_of_fd_exn_slow fd =
	let task_id = ref None in
	let content_length = ref None in

	(* Initial line has the response code on it *)
	let line = input_line_fd fd in
	match String.split_f String.isspace line with
		| http_version :: code :: rest ->
			let version = match String.split ~limit:2 '/' http_version with
				| [ "HTTP"; version ] -> version
				| _ ->
					error "Failed to parse HTTP response status line [%s]" line;
					raise (Parse_error (Printf.sprintf "Failed to parse %s" http_version)) in
			let message = String.concat " " rest in
			let end_of_headers = ref false in
			let headers = ref [] in
			while not !end_of_headers do
				let line = input_line_fd fd in
				(* NB input_line removes the final '\n'.
				   RFC1945 says to expect a '\r\n' (- '\n' = '\r') *)
				match line with       
					| "" | "\r" -> end_of_headers := true
					| x ->
						let k, v = match String.split ~limit:2 ':' x with
							| [ k; v ] -> String.lowercase k, String.strip String.isspace v
							| _        -> "", "" in
						if k = String.lowercase Http.Hdr.task_id then task_id := Some v
						else if k = String.lowercase Http.Hdr.content_length then content_length := Some (Int64.of_string v)
						else headers := (k, v) :: !headers
			done;
			{
				Http.Response.version = version;
				code = code;
				message = message;
				content_length = !content_length;
				task = !task_id;
				additional_headers = !headers;
				body = None;
			}
		| _ ->
			error "Failed to parse HTTP response status line [%s]" line;
			raise (Parse_error (Printf.sprintf "Expected initial header [%s]" line))

(** [response_of_fd_exn fd] returns an Http.Response.t object, or throws an exception *)
let response_of_fd_exn fd =
	let buf = String.create 1024 in
	let b = Http.read_http_response_header buf fd in
	let buf = String.sub buf 0 b in

	let open Http.Response in
	snd(List.fold_left
		(fun (status, res) header ->
			if not status then begin
				match String.split ~limit:3 ' ' header with
					| [ http_version; c; rest ] ->
						begin match String.split ~limit:2 '/' http_version with
							| [ "HTTP"; version ] -> 
								true, { res with version = version; code = c; message = rest }
							| _ ->
								error "Failed to parse HTTP response status line [%s]" header;
								raise (Parse_error (Printf.sprintf "Failed to parse %s" http_version))
						end
					| _ -> raise (Parse_error (Printf.sprintf "Failed to parse %s" header))
			end else begin
				match String.split ~limit:2 ':' header with
					| [ k; v ] ->
						let k = String.lowercase k in
						let v = String.strip String.isspace v in
						true, begin match k with
							| k when k = Http.Hdr.task_id -> { res with task = Some v }
							| k when k = Http.Hdr.content_length -> { res with content_length = Some (Int64.of_string v) }
							| k -> { res with additional_headers = (k, v) :: res.additional_headers }
						end
					| _ -> true, res (* end of headers? *)
			end
		) (false, empty) (String.split '\n' buf))

(** [response_of_fd fd] returns an optional Http.Response.t record *)
let response_of_fd ?(use_fastpath=false) fd =
	try
		if use_fastpath
		then Some(response_of_fd_exn fd)
		else Some (response_of_fd_exn_slow fd)
	with _ -> None

(** See perftest/tests.ml *)
let last_content_length = ref 0L

let http_rpc_recv_response use_fastpath error_msg fd =
	match response_of_fd ~use_fastpath fd with
		| None -> raise (Http_request_rejected error_msg)
		| Some response ->
			begin match response.Http.Response.code with
				| ("401"|"403"|"500") as http_code -> raise (Http_error (http_code,error_msg))
				| "200" ->
					Opt.iter (fun x -> last_content_length := x) response.Http.Response.content_length;
					response
				| code -> raise (Http_request_rejected (Printf.sprintf "%s: %s" code error_msg))
			end

(** [rpc request f] marshals the HTTP request represented by [request] and [body]
    and then parses the response. On success, [f] is called with an HTTP response record.
    On failure an exception is thrown. *)
let rpc ?(use_fastpath=false) (fd: Unix.file_descr) request f =
(*	Printf.printf "request = [%s]" (Http.Request.to_wire_string request);*)
	http_rpc_send_query fd request;
	f (http_rpc_recv_response use_fastpath (Http.Request.to_string request) fd) fd

