(** Representation of S-expression grammars *)

(** This module defines the representation of S-expression grammars produced by
    [@@deriving sexp_grammar].  It introduces an AST to represent these grammars and a
    notion of "group" to represent the grammars of a mutually recursive set of OCaml
    type declaration.

    The grammar for a given type expression can be constructed via:

    {[
      [%sexp_grammar: <type>]
    ]}

    {3 Goals and non-goals}

    Functionality goals: With post-processing, sexp grammars can be pretty-printed in a
    human-readable format and provides enough information to implement completion and
    validation tools.

    Performance goals: This module makes sure that the overhead of adding [@@deriving
    sexp_grammar] is minimal and introduces no toplevel side effect. It also makes sure
    that the compiler can lift the vast majority of ASTs generated by [@@deriving
    sexp_grammar] as global constants, ensuring maximum sharing between grammars, in
    particular the ones coming from functor applications.

    Non-goals: Stability, although we will make changes backwards-compatible or at least
    provide a reasonable upgrade path.

    In what follows, we describe how this is achieved.

    {3 Encoding of generated grammars}

    The grammars of a mutually recursive group of OCaml type declarations are grouped
    under a single [group].  A group is split into two parts: a generic part and an
    instance.  The generic part depends only on the textual type declarations.  In
    particular, it doesn't depend on the actual grammars of the types referenced in the
    type declarations.  This means that it can always be lifted as a shared global
    constant by the compiler, ensuring maximum sharing.  The instance part depends on
    the grammar of the referenced types.

    To achieve that, the generic part only records the names of the types referenced
    and the instance part associates concrete grammars to these names.  This is basically
    the same as splitting each types in two types: a generic shared one and an instance
    of the generic one.

    To understand this point better, let's consider the following type declaration:

    {[
      type t = X of u
    ]}

    the generic and instance parts can be seen as the following types:

    {[
      type 'u t_generic = X of 'u
      type t_instance = u t_generic
    ]}

    If [u] came from a functor argument, it's easy to see that [t_generic] would be
    exactly the same in all application of the functor and only [t_instance] would vary.
    The grammar of [t_generic], which is the biggest part would be shared between all
    applications of the functor.

    {3 Processing of grammars}

    The grammars generated by [@@deriving sexp_grammar] are a bit raw and tend to
    contain a lot of variables since they contain no direct references to other types.
    Displaying such grammars in this way to the user wouldn't be great.  At the same
    time, we still want to share as much as possible in the final grammar in order for
    it to be as small as possible.

    To improve the generated grammars, we remove all type variables that are always
    instantiated only once in a given grammar.

    In order to make this processing more efficient, we keep two kind of identifiers in
    the generated grammars:

    - generic group identifiers that uniquely identify a generic group
    - group idenfitiers that unique identify a group instance

    For generic group identifiers, we simply use a hash of the actual AST given that the
    generic part has no dependency.

    For the second kind of identifiers, we generate a unique integer identifier.  The
    integer is generated lazily so that we don't create a side effect at module creation
    time.
*)

(** The label of a field, constructor, or constant. *)
type label = string

type generic_group_id = string
type group_id = Lazy_group_id.t

(** Variable names. These are used to improve readability of the printed grammars.
    Internally, we use numerical indices to represent variables; see [Implicit_var]
    below. *)
type var_name = string

type type_name = string

(** A grammatical type which classifies atoms. *)
module Atom = struct
  type t =
    | String  (** Any atom. *)
    | Bool  (** One of [true], [false], [True], or [False]. *)
    | Char  (** A single-character atom. *)
    | Float  (** An atom which parses as a {!float}. *)
    | Int  (** An atom which parses as an integer, such as {!int} or {!int64}. *)
    | This of { ignore_capitalization : bool; string : string }
    (** Exactly that string, possibly modulo case in the first character. *)
end

(** A grammatical type which classifies sexps. Corresponds to a non-terminal in a
    context-free grammar. *)
type 't type_ =
  | Any  (** Any list or atom. *)
  | Apply of 't type_ * 't type_ list  (** Assign types to (explicit) type variables. *)
  | Atom of Atom.t  (** An atom, in particular one of the given {!Atom.t}. *)
  | Explicit_bind of var_name list * 't type_
  (** In [Bind ([ "a"; "b" ], Explicit_var 0)], [Explicit_var 0] is ["a"]. One must bind
      all available type variables: free variables are not permitted. *)
  | Explicit_var of int
  (** Indices for type variables, e.g. ['a], introduced by polymorphic definitions.

      Unlike de Bruijn indices, these are always bound by the nearest ancestral
      [Explicit_bind]. *)
  | Grammar of 't  (** Embeds other types in a grammar. *)
  | Implicit_var of int
  (** Indices for type constructors, e.g. [int], in scope. Unlike de Bruijn indices, these
      are always bound by the [implicit_vars] of the nearest enclosing [generic_groups].
  *)
  | List of 't sequence_type
  (** A list of a certain form. Depending on the {!sequence_type}, this might
      correspond to an OCaml tuple, list, or embedded record. *)
  | Option of 't type_
  (** An optional value. Either syntax recognized by [option_of_sexp] is supported:
      [(Some 42)] or [(42)] for a value and [None] or [()] for no value. *)
  | Record of 't record_type
  (** A list of lists, representing a record of the given {!record_type}. For
      validation, [Record recty] is equivalent to [List [Fields recty]]. *)
  | Recursive of type_name
  (** A type in the same mutually recursive group, possibly the current one. *)
  | Union of 't type_ list
  (** Any sexp matching any of the given types. {!Variant} should be preferred when
      possible, especially for complex types, since validation and other algorithms may
      behave exponentially.

      One useful special case is [Union []], the empty type. This is occasionally
      generated for things such as abstract types. *)
  | Variant of 't variant_type  (** A sexp which matches the given {!variant_type}. *)

(** A grammatical type which classifies sequences of sexps. Here, a "sequence" may mean
    either a list on its own or, say, the sexps following a constructor in a list
    matching a {!variant_type}.

    Certain operations may greatly favor simple sequence types. For example, matching
    [List [ Many type_ ]] is easy for any type [type_] (assuming [type_] itself is
    easy), but [List [ Many type1; Many type2 ]] may require backtracking. Grammars
    derived from OCaml types will only have "nice" sequence types. *)
and 't sequence_type = 't component list

(** Part of a sequence of sexps. *)
and 't component =
  | One of 't type_  (** Exactly one sexp of the given type. *)
  | Optional of 't type_  (** One sexp of the given type, or nothing at all. *)
  | Many of 't type_  (** Any number of sexps, each of the given type. *)
  | Fields of 't record_type
  (** A succession of lists, collectively defining a record of the given {!record_type}.
      The fields may appear in any order. The number of lists is not necessarily fixed,
      as some fields may be optional. In particular, if all fields are optional, there
      may be zero lists. *)

(** A tagged union of grammatical types. Grammars derived from OCaml variants will have
    variant types. *)
and 't variant_type =
  { ignore_capitalization : bool
  (** If true, the grammar is insensitive to the case of the first letter of the label.
      This matches the behavior of derived [sexp_of_t] functions. *)
  ; alts : (label * 't sequence_type) list
  (** An association list of labels (constructors) to sequence types. A matching sexp is
      a list whose head is the label as an atom and whose tail matches the given
      sequence type. As a special case, an alternative whose sequence is empty matches
      an atom rather than a list (i.e., [label] rather than [(label)]). This is in
      keeping with generated [t_of_sexp] functions.

      As a workaround, to match [(label)] one could use
      [("label", [ Optional (Union []) ])]. *)
  }

(** A collection of field definitions specifying a record type. Consists only of an
    association list from labels to fields. *)
and 't record_type =
  { allow_extra_fields: bool
  ; fields: (label * 't field) list
  }

(** A field in a record. *)
and 't field =
  { optional : bool  (** If true, the field is optional. *)
  ; args : 't sequence_type
  (** A sequence type which the arguments to the field must match. An empty sequence is
      permissible but would not be generated for any OCaml type. *)
  }

type t =
  | Ref of type_name * group
  | Inline of t type_

and group =
  { gid : group_id
  ; generic_group : generic_group
  ; origin : string
  (** [origin] provides a human-readable hint as to where the type was defined.

      For a globally unique identifier, use [gid] instead.

      See [ppx/ppx_sexp_conv/test/expect/test_origin.ml] for examples. *)
  ; apply_implicit : t list
  }

and generic_group =
  { implicit_vars : var_name list
  ; ggid : generic_group_id
  ; types : (type_name * t type_) list
  }

module type Placeholder = sig
  val t_sexp_grammar : t
end
