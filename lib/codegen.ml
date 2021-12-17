(* Turn AST into assembly *)

open Lexer
open Parser

let generate_begin =
"
; Generated by Paper-lang compiler
section .data
  out: db '%d', 10, 0

section .text
global _start       ; Provide program starting address to linker
"

let generate_startup =
"
extern printf

_start:
  ; Preallocate 1024 bytes on the stack to use for the whole program (for now)
  sub rsp, 1024

"

let generate_end =
"
  add rsp, 1024 ; Return stack pointer to start 
"

let generate_exit = "
  ; Load Linux exit syscall
  mov rdi, 0
  mov rax, 60
  syscall
"

type offset = int
type generator = {
  variables: (string, offset) Hashtbl.t;
  filepath: string;
  channel: out_channel
}

let new_generator filename =
  let filepath = (Filename.chop_extension filename) ^ ".s" in
  {
    variables = Hashtbl.create 100;
    filepath;
    channel = open_out filepath
  }

let close_generator generator = close_out generator.channel

let alloc_var var_name (g: generator) = if Hashtbl.mem g.variables var_name then
                                          failwith "Var already exists!!!"
                                        else
                                          Hashtbl.add g.variables var_name 0; 0

let gen_plus_op a b =
"  mov rax, " ^ (string_of_int a) ^ "\n" ^
"  mov rcx, " ^ (string_of_int b) ^ "\n" ^
"  add rax, rcx ; output of addition is now in rax\n"

let gen_print = 
"
  mov edi, out      ; 64-bit ABI passing order starts w/ edi, esi, ... so format string goes into the first argument
  mov esi, [rsp+0]  ; arg1 goes into esi
  mov eax, 0        ; printf has varargs so eax counts num. of non-integer arguments being passed
  call printf
"

let gen_from_expr _gen expr = match expr with
  | Binary b -> begin
    match b.operator with
    | t when t.token_type = Plus -> begin
      match b.left_expr, b.right_expr with
      | Literal (_, NumberLiteral a), Literal (_, NumberLiteral b) ->
        gen_plus_op a b
      | _ -> failwith "Cant add these types"
    end
    | _ -> ""
  end
  | _ -> ""

(* let gen_store register memory_location = "mov " *)

let gen_from_stmt gen (ast: statement) = match ast with
  | Expression e ->
    begin
      match e with
      | Assign assignment ->
        (* Compute what we want to store in it *)
        let value_calculation = gen_from_expr gen assignment.expr in
        (* Allocate the variable to keep track of it *)
        let _offset = alloc_var assignment.identifier gen in
        value_calculation ^ "  mov [rsp+0], rax ; move result to first byte on the stack\n"
      | _ -> ""
    end
  | Print _e -> gen_print

let codegen gen (ast: statement list) : string = 
  let _stmt = List.nth ast 0 in
  let asm = ref "" in
  let rec inner stmts = match stmts with
    | [] -> !asm
    | s :: rest ->
      let next = gen_from_stmt gen s in
      asm := !asm ^ next ^ "\n" ^ (inner rest);
      !asm
  in
  let final = inner ast in
  let output = generate_begin ^ generate_startup ^  final ^ generate_end ^ generate_exit in
  output

let test_gen () = 
  let s = "let a = 10 + 10\nprint 10\n" in
  let gen = new_generator "output.s" in
  let tokens = tokenise s in List.iter print_token tokens;
  let ast = tokenise s |> parse in List.iter print_stmt ast;
  let asm = s |> tokenise |> parse |> codegen gen in
  (* print_endline asm; *)
  let ch = open_out "output.s" in
  Printf.fprintf ch "%s" asm