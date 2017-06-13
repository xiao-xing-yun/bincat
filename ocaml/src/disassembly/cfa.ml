(*
    This file is part of BinCAT.
    Copyright 2014-2017 - Airbus Group

    BinCAT is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as published by
    the Free Software Foundation, either version 3 of the License, or (at your
    option) any later version.

    BinCAT is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with BinCAT.  If not, see <http://www.gnu.org/licenses/>.
*)

(** the control flow automaton functor *)

module L = Log.Make(struct let name = "cfa" end)

module Make(Domain: Domain.T) =
struct
  (** Abstract data type of nodes of the CFA *)
  module State =
  struct
    
	(** data type for the decoding context *)
	type ctx_t = {
	  addr_sz: int; (** size in bits of the addresses *)
	  op_sz  : int; (** size in bits of operands *)
	}
      
	(** abstract data type of a state *)
	type t = {
	  id: int; 	     		    (** unique identificator of the state *)
	  mutable ip: Data.Address.t;   (** instruction pointer *)
	  mutable v: Domain.t; 	    (** abstract value *)
	  mutable ctx: ctx_t ; 	    (** context of decoding *)
	  mutable stmts: Asm.stmt list; (** list of statements of the succesor state *)
	  mutable final: bool;          (** true whenever a widening operator has been applied to the v field *)
	  mutable back_loop: bool; (** true whenever the state belongs to a loop that is backward analysed *)
	  mutable forward_loop: bool; (** true whenever the state belongs to a loop that is forward analysed in CFA mode *)
	  mutable branch: bool option; (** None is for unconditional predecessor. Some true if the predecessor is a If-statement for which the true branch has been taken. Some false if the false branch has been taken *)
	  mutable bytes: char list;      (** corresponding list of bytes *)
	  mutable is_tainted: bool (** true whenever a source left value is the stmt list (field stmts) may be tainted *)
	}
      
	(** the state identificator counter *)
	let state_cpt = ref 0
      
	(** returns a fresh state identificator *)
	let new_state_id () = state_cpt := !state_cpt + 1; !state_cpt
      
	(** state equality returns true whenever they are the physically the same (do not compare the content) *)
	let equal s1 s2   = s1.id = s2.id
      
	(** state comparison: returns 0 whenever they are the physically the same (do not compare the content) *)
	let compare s1 s2 = s1.id - s2.id
	(** otherwise return a negative integer if the first state has been created before the second one; a positive integer if it has been created later *)
      
	(** hashes a state *)
	let hash b 	= b.id
      
  end

  module G = Graph.Imperative.Digraph.ConcreteBidirectional(State)
  open State
  
  (** type of a CFA *)
  type t = G.t
    
  (* utilities for memory and register initialization with respect to the provided configuration *)
  (***********************************************************************************************)

        
  (* return the given domain updated by the initial values and intitial tainting for registers with respected ti the provided configuration *)
  let init_registers d =
	let check b sz name =
	  if (String.length (Bits.z_to_bit_string b)) > sz then
	    L.abort (fun p -> p "Illegal initialisation for register %s" name)
	in
	let check_mask b m sz name =
	  if (String.length (Bits.z_to_bit_string b)) > sz || (String.length (Bits.z_to_bit_string m)) > sz then
	    L.abort (fun p -> p "Illegal initialization for register %s" name)
	in
	(* checks whether the provided value is compatible with the capacity of the parameter of type Register _r_ *)
	let check_init_size r (c, t) =
	  let sz   = Register.size r in
	  let name = Register.name r in
	  begin
	    match c with
	    | Config.Content c    -> check c sz name
	    | Config.CMask (b, m) -> check_mask b m sz name
	    | _ -> L.abort (fun p -> p "Illegal memory init \"|xx|\" spec used for register")
	  end;
	  begin
	    match t with
	    | Some (Config.Taint c)      -> check c sz name
	    | Some (Config.TMask (b, m)) -> check_mask b m sz name
	    | _ -> ()
	  end;
	  (c, t)
	in
	(* the domain d' is updated with the content for each register with initial content and tainting value given in the configuration file *)
	Hashtbl.fold
	  (fun r v d ->
	    let region = if Register.is_stack_pointer r then Data.Address.Stack else Data.Address.Global
	    in
	    Domain.set_register_from_config r region (check_init_size r v) d
	  )
	  Config.register_content d
      

    (* main function to initialize memory locations (Global/Stack/Heap) both for content and tainting *)
    (* this filling is done by iterating on corresponding tables in Config *)
  let init_mem domain region content_tbl =
    Hashtbl.fold (fun (addr, nb) content domain ->
      let addr' = Data.Address.of_int region addr !Config.address_sz in
      Domain.set_memory_from_config addr' Data.Address.Global content nb domain
    ) content_tbl domain
    (* end of init utilities *)
    (*************************)
      
  (* CFA creation.
      Return the abstract value generated from the Config module *)
  let init_abstract_value () =
    let d  = List.fold_left (fun d r -> Domain.add_register r d) (Domain.init()) (Register.used()) in
	(* initialisation of Global memory + registers *)
	let d' = init_mem (init_registers d) Data.Address.Global Config.memory_content in
	(* init of the Stack memory *)
	let d' = init_mem d' Data.Address.Stack Config.stack_content in
	(* init of the Heap memory *)
	init_mem d' Data.Address.Heap Config.heap_content
	  
  let init_state (ip: Data.Address.t): State.t =
	let d' = init_abstract_value () in
	{
	  id = 0;
	  ip = ip;
	  v = d';
	  final = false;
	  back_loop = false;
	  forward_loop = false;
	  branch = None;
	  stmts = [];
	  bytes = [];
	  ctx = {
		op_sz = !Config.operand_sz;
		addr_sz = !Config.address_sz;
	  };
	  is_tainted = false;
	}
	

  (* CFA utilities *)
  (*****************)
  
  let copy_state g v = 
    let v = { v with id = new_state_id() } in
	G.add_vertex g v;
	v
      
 	
  let create () = G.create ()
					
  let remove_state (g: t) (v: State.t): unit = G.remove_vertex g v
    
  let remove_successor (g: t) (src: State.t) (dst: State.t): unit = G.remove_edge g src dst
	
 
  let add_state (g: t) (v: State.t): unit = G.add_vertex g v

  let add_successor g src dst = G.add_edge g src dst

  
  (** returns the list of successors of the given vertex in the given CFA *)
  let succs g v  = G.succ g v
  
  let iter_state (f: State.t -> unit) (g: t): unit = G.iter_vertex f g
  
  let pred (g: t) (v: State.t): State.t =
	try List.hd (G.pred g v)
	with _ -> raise (Invalid_argument "vertex without predecessor")

  let sinks (g: t): State.t list =
	G.fold_vertex (fun v l -> if succs g v = [] then v::l else l) g []
	  
  let last_addr (g: t) (ip: Data.Address.t): State.t =
	let s = ref None in
	let last s' =
	  if Data.Address.compare s'.ip ip = 0 then
	    match !s with
	    | None -> s := Some s'
	    | Some prev -> if prev.id < s'.id then s := Some s'
	in
	G.iter_vertex last g;
	match !s with
	| None -> raise Not_found
	| Some s'   -> s'
	   
  let print (dumpfile: string) (g: t): unit =
	let f = open_out dumpfile in
	(* state printing (detailed) *)
	let print_ip s =
	  let bytes = List.fold_left (fun s c -> s ^" " ^ (Printf.sprintf "%02x" (Char.code c))) "" s.bytes in
	  Printf.fprintf f "[node = %d]\naddress = %s\nbytes =%s\nfinal =%s\ntainted=%s\n" s.id
        (Data.Address.to_string s.ip) bytes (string_of_bool s.final) (string_of_bool s.is_tainted);
      List.iter (fun v -> Printf.fprintf f "%s\n" v) (Domain.to_string s.v);
	  if !Config.loglevel > 2 then
	    begin
	      Printf.fprintf f "statements =";
	      List.iter (fun stmt -> Printf.fprintf f " %s\n" (Asm.string_of_stmt stmt true)) s.stmts;
	    end;
	  Printf.fprintf f "\n";
	in
	G.iter_vertex print_ip g;
	(* edge printing (summary) *)
	Printf.fprintf f "[edges]\n";
	G.iter_edges_e (fun e -> Printf.fprintf f "e%d_%d = %d -> %d\n" (G.E.src e).id (G.E.dst e).id (G.E.src e).id (G.E.dst e).id) g;
	close_out f;;
	

  let marshal (outfname: string) (cfa: t): unit =
	let cfa_marshal_fd = open_out_bin outfname in
	Marshal.to_channel cfa_marshal_fd cfa [];
	Marshal.to_channel cfa_marshal_fd !state_cpt [];
	close_out cfa_marshal_fd;;
  
  let unmarshal (infname: string): t =
	let cfa_marshal_fd = open_in_bin infname in
	let origcfa = Marshal.from_channel cfa_marshal_fd in
	let last_id = Marshal.from_channel cfa_marshal_fd in
	state_cpt := last_id;
	close_in cfa_marshal_fd;
    origcfa
        
end
(** module Cfa *)
