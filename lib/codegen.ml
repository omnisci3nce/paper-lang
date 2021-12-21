(* Turn AST into assembly *)

open Lexer
open Parser
(* open Helpers *)
let _STACK_SIZE = 1024

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
extern addTen

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

type calling_convention = Microsoft_x64 | System_V

(* type offset = int *)
type generator = {
  variables: (string, int) Hashtbl.t;
  mutable instruction_count: int;
  mutable asm: string;
  filepath: string;
  channel: out_channel
}

module type CodeGenerator = sig
  val new_generator : string -> generator
  val close_generator : generator -> unit

  val gen_plus_op : string -> string -> generator -> (string * int)
  val gen_mult_op : string -> string -> generator -> (string * int)
  val gen_print : string -> generator -> generator
end

module JSBackend : CodeGenerator = struct
  let new_generator filename =
    let filepath = (Filename.chop_extension filename) ^ ".js" in
    {
      variables = Hashtbl.create 100;
      asm = "";
      instruction_count = 0;
      filepath;
      channel = open_out filepath
    }
  let close_generator g = close_out g.channel

  let gen_plus_op _a _b _gen = 
    (* Allocate temp var *)
    let _s = "temp_var = a + b" in
    ("", 0)
  let gen_mult_op _a _b _gen = ("", 0)
  let gen_print _var gen = gen
end

let new_generator filename =
  let filepath = (Filename.chop_extension filename) ^ ".s" in
  {
    variables = Hashtbl.create 100;
    asm = "";
    instruction_count = 0;
    filepath;
    channel = open_out filepath
  }

let close_generator generator = close_out generator.channel

(* emit one line of asm *)
let emit str gen =
  gen.instruction_count <- gen.instruction_count + 1;
  gen.asm <- gen.asm ^ "  " ^ str ^ "\n";
  gen

  

module Instr = struct
  (*  *)
end
  
let bottom_var g = Hashtbl.fold (fun _ v c -> if v >= c then (v+8) else c) g.variables 0
let empty_var g i = (bottom_var g)+(8*(i-1))

let is_alloc_var gen var_name = Hashtbl.mem gen.variables var_name
let alloc_var var_name (g: generator) = if Hashtbl.mem g.variables var_name then
                                          failwith "Var already exists!!!"
                                        else
                                          let available = empty_var g 1 in
                                          Logs.debug (fun m -> m "[Codegen] Allocating variable '%s' at offset %d" var_name available);
                                          Hashtbl.add g.variables var_name available; available
let temp_v_counter = ref 1
let alloc_temp_var g = 
  let var_name = ("__temp" ^ (string_of_int !temp_v_counter))  in
  if Hashtbl.mem g.variables var_name then
    failwith "Var already exists!!!"
  else let available = empty_var g 1 in
    temp_v_counter := !temp_v_counter + 1;
    Logs.debug (fun m -> m "[Codegen] Allocating temp variable '%s' at offset %d" var_name available);
    Hashtbl.add g.variables var_name available; (var_name, available)
      
let gen_plus_op a b gen =
  let name, offset = alloc_temp_var gen in
  let _ = gen
  |> emit ("mov rax, " ^ a)
  |> emit ("mov rcx, " ^ b)
  |> emit "add rax, rcx ; output of addition is now in rax"
  |> emit ("mov [rsp+" ^ string_of_int offset ^ "], rax ; move onto stack")
  in
  (name, offset)

let gen_mult_op a b gen =
  let name, offset = alloc_temp_var gen in
  let _ = gen
  |> emit ("mov rax, " ^ a)
  |> emit ("mov rdx, " ^ b)
  |> emit "mul rdx ; output of addition is now in rax"
  |> emit ("mov [rsp+" ^ string_of_int offset ^ "], rax ; move onto stack")
  in
  (name, offset)

let gen_print var_name gen = 
  let offset = Hashtbl.find gen.variables var_name in
emit ("
  mov edi, out      ; 64-bit ABI passing order starts w/ edi, esi, ... so format string goes into the first argument
  mov esi, [rsp+" ^ string_of_int offset ^ "]  ; arg1 goes into esi
  mov eax, 0        ; printf has varargs so eax counts num. of non-integer arguments being passed
  call printf
") gen

let gen_add_ten _a gen =
  (* let name, offset = alloc_temp_var gen in *)
  let _ = gen
  |> emit ("
    mov rdi, 5
    mov rax, 0
    call addTen
    mov [rsp+0], rax
  ") in
  gen

let var g s = "[rsp+" ^ string_of_int (Hashtbl.find g.variables s) ^ "]"

let rec gen_from_expr gen expr : (generator * string) = match expr with
  | Grouping e -> gen_from_expr gen e.expr
  | Binary b -> begin
    match b.operator with
    | t when t.token_type = Plus -> begin
      match b.left_expr, b.right_expr with
      (* Num + Num *)
      | IntConst a,  IntConst b ->
        let (name, _) = gen_plus_op (string_of_int a) (string_of_int b) gen in
        (* print_hashtbl gen.variables; *)
        gen, name
      (* Num + Expr *)
      | IntConst a, e ->
        let (new_gen, temp_name) = gen_from_expr gen e in
        let (name, _offset) = gen_plus_op (string_of_int a) (var new_gen temp_name) new_gen in
        new_gen, name
      (* Expr + Num *)
      | e, IntConst a ->
        let (new_gen, temp_name) = gen_from_expr gen e in
        let (name, _offset) = gen_plus_op (string_of_int a) (var new_gen temp_name) new_gen in
        new_gen, name
      
      (* Or *)
      (* Expr + Num *)
     
      | _ -> failwith "Cant add these types"
    end
    | t when t.token_type = Star -> begin
      match b.left_expr, b.right_expr with
      (* Num + Num *)
      | IntConst a, IntConst b ->
        let (name, _) = gen_mult_op (string_of_int a) (string_of_int b) gen in
        gen, name
      | IntConst a, e ->
        let (new_gen, temp_name) = gen_from_expr gen e in
        let (name, _offset) = gen_mult_op (string_of_int a) (var new_gen temp_name) new_gen in
        new_gen, name
      | e, IntConst a ->
        let (new_gen, temp_name) = gen_from_expr gen e in
        let (name, _offset) = gen_mult_op (string_of_int a) (var new_gen temp_name) new_gen in
        new_gen, name
      | _ -> failwith "Cant multiply these types"
    end
    | _ -> failwith "todo : implement this operator for binary expression"
  end
  | _ -> gen, "todo: handle this expression in generator"

let generate_copy_ident target name gen = 
  gen
  |> emit ("mov rax, " ^ var gen name)
  |> emit ("mov " ^ var gen target ^ ", rax")

let gen_from_stmt gen (ast: statement) = match ast with
  | LetDecl e ->
        (* Check if var has already been allocated *)
        let _offset = if is_alloc_var gen e.identifier then
          Hashtbl.find gen.variables e.identifier
        else 
        (* Allocate the variable to keep track of it *)
          alloc_var e.identifier gen
        in
        (* Compute what we want to store in it *)
        let (new_gen, name) = gen_from_expr gen e.expr in
        (* print_hashtbl gen.variables; *)
        (* let _ = generate_copy_ident e.identifier name gen in  *)
        (* let _offset2 = Hashtbl.find new_gen.variables name in *)
        let new_gen = generate_copy_ident e.identifier name new_gen in
        new_gen
  | Print e -> begin
    match e with
    | Var v -> gen_print v gen
    | _ -> gen
  end
  | _ -> gen

let codegen gen (ast: statement list) : string = 
  let _stmt = List.nth ast 0 in
  let rec inner gen stmts = match stmts with
    | [] -> gen
    | s :: rest ->
      let next = gen_from_stmt gen s in
      inner next rest
  in
  let final = inner gen ast in
  (* let final = gen_add_ten "5" final in *)
  let final = gen_print "a" final in (* TODO: fix print statement parsing so I dont have to tack this on manually at the end *)
  let output = generate_begin ^ generate_startup ^  final.asm ^ generate_end ^ generate_exit in
  output

type target = AMD64 | AARCH_64 | RISCV | JS | WASM (* Target platforms that I'd like to support *)

let compile ~target filepath (_ast: statement list) =
  let gen = match target with
    | AMD64 -> new_generator filepath
    | AARCH_64 -> failwith "This backend is not implemented yet"
    | RISCV -> failwith "This backend is not implemented yet"
    | JS -> failwith "This backend is not implemented yet"
    | WASM -> failwith "This backend is not implemented yet"
  in
  let ch = open_out "output.js" in
  Printf.fprintf ch "%s" gen.asm 

let test_gen () = 
  let s = "let a = (10 * 5) + 10\n" in
  let t = s |> tokenise in List.iter print_token t;
  let gen = new_generator "output.s" in
  print_endline "Parsed:";
  let ast = s |> tokenise |> parse  in List.iter print_stmt ast; print_newline ();
  print_string "Num temp vars: "; print_int !temp_v_counter; print_newline ();
  let asm = ast |> codegen gen in (* tokenise -> parse -> generate assembly *)
  print_string "Instruction count: "; print_int gen.instruction_count; print_newline ();
  let ch = open_out gen.filepath in
  Printf.fprintf ch "%s" asm (* write assembly to file *)