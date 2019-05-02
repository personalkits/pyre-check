(** Copyright (c) 2016-present, Facebook, Inc.

    This source code is licensed under the MIT license found in the
    LICENSE file in the root directory of this source tree. *)

open Core
open OUnit2

open Analysis
open Ast
open Pyre
open PyreParser
open Statement


let initialize () =
  Memory.get_heap_handle (Configuration.Analysis.create ())
  |> ignore;
  Log.initialize_for_tests ();
  Statistics.disable ();
  Type.Cache.disable ()


let () =
  initialize ()


let trim_extra_indentation source =
  let is_non_empty line =
    not (String.for_all ~f:Char.is_whitespace line) in
  let minimum_indent lines =
    let indent line =
      String.to_list line
      |> List.take_while ~f:Char.is_whitespace
      |> List.length in
    List.filter lines ~f:is_non_empty
    |> List.map ~f:indent
    |> List.fold ~init:Int.max_value ~f:Int.min in
  let strip_line minimum_indent line =
    if not (is_non_empty line) then
      line
    else
      String.slice line minimum_indent (String.length line) in
  let strip_lines minimum_indent = List.map ~f:(strip_line minimum_indent) in
  let lines =
    String.rstrip source
    |> String.split ~on:'\n' in
  let minimum_indent = minimum_indent lines in
  strip_lines minimum_indent lines
  |> String.concat ~sep:"\n"


let run tests =
  let rec bracket test =
    let bracket_test test context =
      initialize ();
      test context;
      Unix.unsetenv "HH_SERVER_DAEMON_PARAM";
      Unix.unsetenv "HH_SERVER_DAEMON"
    in
    match test with
    | OUnitTest.TestLabel (name, test) ->
        OUnitTest.TestLabel (name, bracket test)
    | OUnitTest.TestList tests ->
        OUnitTest.TestList (List.map tests ~f:bracket)
    | OUnitTest.TestCase (length, f) ->
        OUnitTest.TestCase (length, bracket_test f)
  in
  tests
  |> bracket
  |> run_test_tt_main


let parse_untrimmed
    ?(handle = "test.py")
    ?(qualifier = Reference.empty)
    ?(debug = true)
    ?(strict = false)
    ?(declare = false)
    ?(version = 3)
    ?(autogenerated = false)
    ?(silent = false)
    ?(docstring = None)
    ?(ignore_lines = [])
    ?(convert = false)
    source =
  let handle = File.Handle.create handle in
  let buffer = Lexing.from_string (source ^ "\n") in
  buffer.Lexing.lex_curr_p <- {
    buffer.Lexing.lex_curr_p with
    Lexing.pos_fname = File.Handle.show handle;
  };
  try
    let source =
      let state = Lexer.State.initial () in
      let metadata =
        Source.Metadata.create
          ~autogenerated
          ~debug
          ~declare
          ~ignore_lines
          ~strict
          ~version
          ~number_of_lines:(-1)
          ()
      in
      Source.create
        ~docstring
        ~metadata
        ~handle
        ~qualifier
        (Generator.parse (Lexer.read state) buffer)
    in
    if convert then
      Preprocessing.convert source
    else
      source
  with
  | Pyre.ParserError _
  | Generator.Error ->
      let location =
        Location.create
          ~start:buffer.Lexing.lex_curr_p
          ~stop:buffer.Lexing.lex_curr_p
      in
      let line = location.Location.start.Location.line - 1
      and column = location.Location.start.Location.column in

      let header =
        Format.asprintf
          "\nCould not parse test at %a"
          Location.Reference.pp location
      in
      let indicator =
        if column > 0 then (String.make (column - 1) ' ') ^ "^" else "^" in
      let error =
        match List.nth (String.split source ~on:'\n') line with
        | Some line -> Format.asprintf "%s:\n  %s\n  %s" header line indicator
        | None -> header ^ "." in
      if not silent then
        Printf.printf "%s" error;
      failwith "Could not parse test"


let parse
    ?(handle = "test.py")
    ?(qualifier = Reference.empty)
    ?(debug = true)
    ?(version = 3)
    ?(docstring = None)
    ?local_mode
    ?(convert = false)
    source =
  Ast.SharedMemory.Handles.add_handle_hash ~handle;
  let ({ Source.metadata; _ } as source) =
    trim_extra_indentation source
    |> parse_untrimmed ~handle ~qualifier ~debug ~version ~docstring ~convert
  in
  match local_mode with
  | Some local_mode ->
      { source with Source.metadata = { metadata with Source.Metadata.local_mode } }
  | _ ->
      source


let parse_list named_sources =
  let create_file (name, source) =
    File.create
      ~content:(trim_extra_indentation source)
      (Path.create_relative ~root:(Path.current_working_directory ()) ~relative:name)
  in
  let { Service.Parser.parsed; _ } =
    Service.Parser.parse_sources
      ~configuration:(
        Configuration.Analysis.create ~local_root:(Path.current_working_directory ()) ())
      ~scheduler:(Scheduler.mock ())
      ~preprocessing_state:None
      ~files:(List.map ~f:create_file named_sources)
  in
  parsed


let parse_single_statement ?(convert = false) ?(preprocess = false) source =
  let source =
    if preprocess then
      Preprocessing.preprocess (parse source)
      |> Preprocessing.convert
    else
      parse ~convert source
  in
  match source with
  | { Source.statements = [statement]; _ } -> statement
  | _ -> failwith "Could not parse single statement"


let parse_last_statement ?(convert = false) source =
  match parse ~convert source with
  | { Source.statements; _ } when List.length statements > 0 ->
      List.last_exn statements
  | _ -> failwith "Could not parse last statement"


let parse_single_define ?(convert = false) source =
  match parse_single_statement ~convert source with
  | { Node.value = Statement.Define define; _ } -> define
  | _ -> failwith "Could not parse single define"


let parse_single_class ?(convert = false) source =
  match parse_single_statement ~convert source with
  | { Node.value = Statement.Class definition; _ } -> definition
  | _ -> failwith "Could not parse single class"


let parse_single_expression ?(convert = false) ?(preprocess = false) source =
  match parse_single_statement ~convert ~preprocess source with
  | { Node.value = Statement.Expression expression; _ } -> expression
  | _ -> failwith "Could not parse single expression."


let parse_single_access ?(convert = false) ?(preprocess = false) source =
  match parse_single_expression ~convert ~preprocess source with
  | { Node.value = Expression.Access (Expression.Access.SimpleAccess access); _ } -> access
  | _ -> failwith "Could not parse single access"


let parse_callable ?(aliases = fun _ -> None) callable =
  parse_single_expression callable
  |> Type.create ~aliases


let diff ~print format (left, right) =
  let escape string =
    String.substr_replace_all string ~pattern:"\"" ~with_:"\\\""
    |> String.substr_replace_all ~pattern:"'" ~with_:"\\\""
    |> String.substr_replace_all ~pattern:"`" ~with_:"?"
    |> String.substr_replace_all ~pattern:"$" ~with_:"?"
  in
  let input =
    Format.sprintf
      "bash -c \"diff -u <(echo '%s') <(echo '%s')\""
      (escape (Format.asprintf "%a" print left))
      (escape (Format.asprintf "%a" print right))
    |> Unix.open_process_in in
  Format.fprintf format "\n%s" (In_channel.input_all input);
  In_channel.close input


let map_printer ~key_pp ~data_pp map =
  let to_string (key, data) =
    Format.asprintf
      "    %a -> %a"
      key_pp key
      data_pp data
  in
  Map.to_alist map
  |> List.map ~f:to_string
  |> String.concat ~sep:"\n"


let assert_source_equal =
  assert_equal
    ~cmp:Source.equal
    ~printer:(fun source -> Format.asprintf "%a" Source.pp source)
    ~pp_diff:(diff ~print:Source.pp)


let assert_type_equal =
  assert_equal
    ~printer:Type.show
    ~cmp:Type.equal


let add_defaults_to_environment ~configuration environment_handler =
  let source =
    parse
      {|
        class unittest.mock.Base: ...
        class unittest.mock.Mock(unittest.mock.Base): ...
        class unittest.mock.NonCallableMock: ...
      |};
  in
  Service.Environment.populate
    ~configuration
    ~scheduler:(Scheduler.mock ())
    environment_handler
    [source]


(* Expression helpers. *)
let (~+) value =
  Node.create_with_default_location value


let (!) name =
  let open Expression in
  +Access (SimpleAccess (Access.create name))


let (!!) name =
  +Statement.Expression (
    +Expression.Name (Expression.create_name ~location:Location.Reference.any name)
  )


let (!+) name =
  Access.create name


let (!&) name =
  Reference.create name


(* Assertion helpers. *)
let assert_true =
  assert_bool ""


let assert_false test =
  assert_bool "" (not test)


let assert_is_some test =
  assert_true (Option.is_some test)


let assert_is_none test =
  assert_true (Option.is_none test)


let assert_unreached () =
  assert_true false


let mock_path path =
  Path.create_relative ~root:(Path.current_working_directory ()) ~relative:path


let write_file (path, content) =
  let content = trim_extra_indentation content in
  let path =
    if (Filename.is_absolute path) then
      Path.create_absolute ~follow_symbolic_links:false path
    else
      mock_path path
  in
  let file = File.create ~content path in
  File.write file;
  file


(* Override `OUnit`s functions the return absolute paths. *)
let bracket_tmpdir ?suffix context =
  bracket_tmpdir ?suffix context
  |> Filename.realpath


let bracket_tmpfile ?suffix context =
  bracket_tmpfile ?suffix context
  |> (fun (filename, channel) -> Filename.realpath filename, channel)


(* Common type checking and analysis setup functions. *)
let mock_configuration =
  Configuration.Analysis.create ()



let typeshed_stubs ?(include_helper_builtins = true) () =
  let builtins =
    let helper_builtin_stubs =
      {|
        import typing

        def not_annotated(input = ...): ...

        def expect_int(i: int) -> None: ...
        def to_int(x: Any) -> int: ...
        def int_to_str(i: int) -> str: ...
        def str_to_int(i: str) -> int: ...
        def optional_str_to_int(i: Optional[str]) -> int: ...
        def int_to_bool(i: int) -> bool: ...
        def int_to_int(i: int) -> int: pass
        def str_float_to_int(i: str, f: float) -> int: ...
        def str_float_tuple_to_int(t: Tuple[str, float]) -> int: ...
        def nested_tuple_to_int(t: Tuple[Tuple[str, float], float]) -> int: ...
        def return_tuple() -> Tuple[int, int]: ...
        def unknown_to_int(i) -> int: ...
        def star_int_to_int( *args, x: int) -> int: ...
        def takes_iterable(x: Iterable[_T]) -> None: ...
        def awaitable_int() -> typing.Awaitable[int]: ...
        def condition() -> bool: ...

        def __test_sink(arg: Any) -> None: ...
        def __test_source() -> Any: ...
        def __user_controlled() -> Any: ...
        class ClassWithSinkAttribute():
          attribute: Any = ...

        class IsAwaitable(typing.Awaitable[int]): pass
        class contextlib.ContextManager(Generic[_T_co]):
          def __enter__(self) -> _T_co:
            pass
        class contextlib.GeneratorContextManager(
            contextlib.ContextManager[_T],
            Generic[_T]):
          pass

        def identity(x: _T) -> _T: ...
        _VR = TypeVar("_VR", str, int)
        def variable_restricted_identity(x: _VR) -> _VR: pass

        def returns_undefined()->Undefined: ...
        class Spooky:
          def undefined(self)->Undefined: ...

        class Attributes:
          int_attribute: int

        class OtherAttributes:
          int_attribute: int
          str_attribute: str

        class A: ...
        class B(A): ...
        class C(A): ...
        class D(B,C): ...
        class obj():
          @staticmethod
          def static_int_to_str(i: int) -> str: ...
      |}
    in
    let builtin_stubs =
      {|
        from typing import (
          TypeVar, Iterator, Iterable, NoReturn, overload, Container,
          Sequence, MutableSequence, Mapping, MutableMapping, Tuple, List, Any,
          Dict, Callable, Generic, Set, AbstractSet, FrozenSet, MutableSet, Sized,
          Reversible, SupportsInt, SupportsFloat, SupportsAbs,
          SupportsComplex, SupportsRound, IO, BinaryIO, Union, final,
          ItemsView, KeysView, ValuesView, ByteString, Optional, AnyStr, Type, Text,
        )

        _T = TypeVar('_T')
        _T_co = TypeVar('_T_co', covariant=True)
        _S = TypeVar('_S')

        class type:
          __name__: str = ...
          def __call__(self, *args: Any, **kwargs: Any) -> Any: ...

        class object():
          __doc__: str
          def __init__(self) -> None: pass
          def __new__(self) -> Any: pass
          def __sizeof__(self) -> int: pass
          def __hash__(self) -> int: ...

        class ellipsis: ...
        Ellipsis: ellipsis

        class BaseException(object): ...
        class Exception(BaseException): ...

        class slice:
          @overload
          def __init__(self, stop: Optional[int]) -> None: ...
          @overload
          def __init__(
            self,
            start: Optional[int],
            stop: Optional[int],
            step: Optional[int] = ...
          ) -> None: ...
          def indices(self, len: int) -> Tuple[int, int, int]: ...

        class range(Sequence[int]):
          @overload
          def __init__(self, stop: int) -> None: ...

        class super:
           @overload
           def __init__(self, t: Any, obj: Any) -> None: ...
           @overload
           def __init__(self, t: Any) -> None: ...
           @overload
           def __init__(self) -> None: ...

        class bool(): ...

        class bytes(): ...

        class float():
          def __add__(self, other) -> float: ...
          def __radd__(self, other: float) -> float: ...
          def __neg__(self) -> float: ...
          def __abs__(self) -> float: ...

        class int:
          @overload
          def __init__(self, x: Union[Text, bytes, SupportsInt] = ...) -> None: ...
          @overload
          def __init__(self, x: Union[Text, bytes, bytearray], base: int) -> None: ...
          def __le__(self, other) -> bool: ...
          def __lt__(self, other: int) -> bool: ...
          def __ge__(self, other) -> bool: ...
          def __gt__(self, other) -> bool: ...
          def __eq__(self, other) -> bool: ...
          def __ne__(self, other_integer) -> bool: ...
          def __add__(self, other: int) -> int: ...
          def __mod__(self, other) -> int: ...
          def __radd__(self, other: int) -> int: ...
          def __neg__(self) -> int: ...
          def __pos__(self) -> int: ...
          def __str__(self) -> str: ...
          def __invert__(self) -> int: ...

        class complex():
          def __radd__(self, other: int) -> int: ...

        class str(Sized, Sequence[str]):
          @overload
          def __init__(self, o: object = ...) -> None: ...
          @overload
          def __init__(self, o: bytes, encoding: str = ..., errors: str = ...) -> None: ...
          def lower(self) -> str: pass
          def upper(self) -> str: ...
          def substr(self, index: int) -> str: pass
          def join(self, iterable: Iterable[str]) -> str: ...
          def __lt__(self, other: int) -> float: ...
          def __ne__(self, other) -> int: ...
          def __add__(self, other: str) -> str: ...
          def __pos__(self) -> float: ...
          def __repr__(self) -> float: ...
          def __str__(self) -> str: ...
          def __getitem__(self, i: Union[int, slice]) -> str: ...
          def __iter__(self) -> Iterator[str]: ...
          def __eq__(self, x: object) -> bool: ...

        class tuple(Sequence[_T_co], Sized, Generic[_T_co]):
          def __init__(self, a: List[_T_co]): ...
          def tuple_method(self, a: int): ...
          def __lt__(self, x: Tuple[_T_co, ...]) -> bool: ...
          def __le__(self, x: Tuple[_T_co, ...]) -> bool: ...
          def __gt__(self, x: Tuple[_T_co, ...]) -> bool: ...
          def __ge__(self, x: Tuple[_T_co, ...]) -> bool: ...
          def __add__(self, x: Tuple[_T_co, ...]) -> Tuple[_T_co, ...]: ...
          def __mul__(self, n: int) -> Tuple[_T_co, ...]: ...
          def __rmul__(self, n: int) -> Tuple[_T_co, ...]: ...
          @overload
          def __getitem__(self, x: int) -> _T_co: ...
          @overload
          def __getitem__(self, x: slice) -> Tuple[_T_co, ...]: ...

        class dict(MutableMapping[_T, _S], Generic[_T, _S]):
          @overload
          def __init__(self, **kwargs: _S) -> None: ...
          @overload
          def __init__(self, map: Mapping[_T, _S], **kwargs: _S) -> None: ...
          @overload
          def __init__(self, iterable: Iterable[Tuple[_T, _S]], **kwargs: _S) -> None:
            ...
          def add_key(self, key: _T) -> None: pass
          def add_value(self, value: _S) -> None: pass
          def add_both(self, key: _T, value: _S) -> None: pass
          def items(self) -> Iterable[Tuple[_T, _S]]: pass
          def __getitem__(self, k: _T) -> _S: ...
          def __setitem__(self, k: _T, v: _S) -> None: ...
          @overload
          def get(self, k: _T) -> Optional[_S]: ...
          @overload
          def get(self, k: _T, default: _S) -> _S: ...
          @overload
          def update(self, __m: Mapping[_T, _S], **kwargs: _S) -> None: ...
          @overload
          def update(self, __m: Iterable[Tuple[_T, _S]], **kwargs: _S) -> None: ...
          @overload
          def update(self, **kwargs: _S) -> None: ...

        class list(Sequence[_T], Generic[_T]):
          @overload
          def __init__(self) -> None: ...
          @overload
          def __init__(self, iterable: Iterable[_T]) -> None: ...

          def __add__(self, x: list[_T]) -> list[_T]: ...
          def __iter__(self) -> Iterator[_T]: ...
          def append(self, element: _T) -> None: ...
          @overload
          def __getitem__(self, i: int) -> _T: ...
          @overload
          def __getitem__(self, s: slice) -> List[_T]: ...
          def __contains__(self, o: object) -> bool: ...

          def __len__(self) -> int: ...

        class set(Iterable[_T], Generic[_T]):
          def __init__(self, iterable: Iterable[_T] = ...) -> None: ...

        def len(o: Sized) -> int: ...
        def isinstance(
          a: object,
          b: Union[type, Tuple[Union[type, Tuple], ...]]
        ) -> bool: ...
        def sum(iterable: Iterable[_T]) -> Union[_T, int]: ...

        def sys.exit(code: int) -> NoReturn: ...

        def eval(source: str) -> None: ...

        def getattr(
          o: object,
          name: str,
          default: Any,
        ) -> Any: ...

        def all(i: Iterable[_T]) -> bool: ...
        _T1 = TypeVar("_T1")
        _T2 = TypeVar("_T2")
        _T3 = TypeVar("_T3")
        _T4 = TypeVar("_T4")
        _T5 = TypeVar("_T5")
        @overload
        def map(func: Callable[[_T1], _S], iter1: Iterable[_T1]) -> Iterator[_S]:
            ...
        @overload
        def map(
            func: Callable[[_T1, _T2], _S], iter1: Iterable[_T1], iter2: Iterable[_T2]
        ) -> Iterator[_S]:
            ...
        @overload
        def map(
            func: Callable[[_T1, _T2, _T3], _S],
            iter1: Iterable[_T1],
            iter2: Iterable[_T2],
            iter3: Iterable[_T3],
        ) -> Iterator[_S]:
            ...
        @overload
        def map(
            func: Callable[[_T1, _T2, _T3, _T4], _S],
            iter1: Iterable[_T1],
            iter2: Iterable[_T2],
            iter3: Iterable[_T3],
            iter4: Iterable[_T4],
        ) -> Iterator[_S]:
            ...
        @overload
        def map(
            func: Callable[[_T1, _T2, _T3, _T4, _T5], _S],
            iter1: Iterable[_T1],
            iter2: Iterable[_T2],
            iter3: Iterable[_T3],
            iter4: Iterable[_T4],
            iter5: Iterable[_T5],
        ) -> Iterator[_S]:
            ...
        @overload
        def map(
            func: Callable[..., _S],
            iter1: Iterable[Any],
            iter2: Iterable[Any],
            iter3: Iterable[Any],
            iter4: Iterable[Any],
            iter5: Iterable[Any],
            iter6: Iterable[Any],
            *iterables: Iterable[Any],
        ) -> Iterator[_S]:
            ...

        class property:
           def getter(self, fget: Any) -> Any: ...
           def setter(self, fset: Any) -> Any: ...
           def deletler(self, fdel: Any) -> Any: ...

        class staticmethod:
           def __init__(self, f: Callable[..., Any]): ...

        class classmethod:
           def __init__(self, f: Callable[..., Any]): ...
      |}
    in
    if include_helper_builtins then
      String.concat ~sep:"\n" [String.rstrip builtin_stubs; helper_builtin_stubs]
    else
      builtin_stubs
  in
  [
    Source.create ~qualifier:(Reference.create "sys") [];
    parse
      ~qualifier:(Reference.create "hashlib")
      ~handle:"hashlib.pyi"
      {|
        _DataType = typing.Union[int, str]
        class _Hash:
          digest_size: int
        def md5(input: _DataType) -> _Hash: ...
      |}
    |> Preprocessing.preprocess;
    parse
      ~qualifier:(Reference.create "typing")
      ~handle:"typing.pyi"
      {|
        class _SpecialForm:
          def __getitem__(self, typeargs: Any) -> Any: ...
        class TypeAlias: ...

        TypeVar = object()
        List = TypeAlias(object)
        Dict = TypeAlias(object)
        Any = object()
        overload = object()
        final = object()

        Callable: _SpecialForm = ...
        Protocol: _SpecialForm = ...
        Type: _SpecialForm = ...
        Tuple: _SpecialForm = ...

        @runtime
        class Sized(Protocol, metaclass=ABCMeta):
            @abstractmethod
            def __len__(self) -> int: ...

        @runtime
        class Hashable(Protocol, metaclass=ABCMeta):
            @abstractmethod
            def __hash__(self) -> int: ...

        _T = TypeVar('_T')
        _S = TypeVar('_S')
        _KT = TypeVar('_KT')
        _VT = TypeVar('_VT')
        _T_co = TypeVar('_T_co', covariant=True)
        _V_co = TypeVar('_V_co', covariant=True)
        _KT_co = TypeVar('_KT_co', covariant=True)
        _VT_co = TypeVar('_VT_co', covariant=True)
        _T_contra = TypeVar('_T_contra', contravariant=True)

        class Generic(): pass

        class Iterable(Protocol[_T_co]):
          def __iter__(self) -> Iterator[_T_co]: pass
        class Iterator(Iterable[_T_co], Protocol[_T_co]):
          def __next__(self) -> _T_co: ...

        class AsyncIterable(Protocol[_T_co]):
          def __aiter__(self) -> AsyncIterator[_T_co]: ...
        class AsyncIterator(AsyncIterable[_T_co], Protocol[_T_co]):
          def __anext__(self) -> Awaitable[_T_co]: ...
          def __aiter__(self) -> AsyncIterator[_T_co]: ...
        class AsyncContextManager(Protocol[_T_co]):
            def __aenter__(self) -> Awaitable[_T_co]:
                ...

            def __aexit__(
                self,
                exc_type: Optional[Type[BaseException]],
                exc_value: Optional[BaseException],
                traceback: Optional[TracebackType],
            ) -> Awaitable[Optional[bool]]:
                ...

        if sys.version_info >= (3, 6):
          class Collection(Iterable[_T_co], Protocol[_T_co]):
            @abstractmethod
            def __len__(self) -> int: ...
          _Collection = Collection
        else:
          class _Collection(Iterable[_T_co], Protocol[_T_co]):
            @abstractmethod
            def __len__(self) -> int: ...
        class Sequence(_Collection[_T_co], Generic[_T_co]): pass

        class Generator(Generic[_T_co, _T_contra, _V_co], Iterator[_T_co]):
          pass

        class AbstractSet(_Collection[_T_co], Generic[_T_co]):
            @abstractmethod
            def __contains__(self, x: object) -> bool: ...
            # Mixin methods
            def __le__(self, s: AbstractSet[typing.Any]) -> bool: ...
            def __lt__(self, s: AbstractSet[typing.Any]) -> bool: ...
            def __gt__(self, s: AbstractSet[typing.Any]) -> bool: ...
            def __ge__(self, s: AbstractSet[typing.Any]) -> bool: ...
            def __and__(self, s: AbstractSet[typing.Any]) -> AbstractSet[_T_co]: ...
            def __or__(self, s: AbstractSet[_T]) -> AbstractSet[Union[_T_co, _T]]: ...
            def __sub__(self, s: AbstractSet[typing.Any]) -> AbstractSet[_T_co]: ...
            def __xor__(self, s: AbstractSet[_T]) -> AbstractSet[Union[_T_co, _T]]: ...
            def isdisjoint(self, s: AbstractSet[typing.Any]) -> bool: ...

        class ValuesView(MappingView, Iterable[_VT_co], Generic[_VT_co]):
            def __contains__(self, o: object) -> bool: ...
            def __iter__(self) -> Iterator[_VT_co]: ...

        class Mapping(_Collection[_KT], Generic[_KT, _VT_co]):
          @abstractmethod
          def __getitem__(self, k: _KT) -> _VT_co:
              ...
          # Mixin methods
          @overload
          def get(self, k: _KT) -> Optional[_VT_co]: ...
          @overload
          def get(self, k: _KT, default: Union[_VT_co, _T]) -> Union[_VT_co, _T]: ...
          def items(self) -> AbstractSet[Tuple[_KT, _VT_co]]: ...
          def keys(self) -> AbstractSet[_KT]: ...
          def values(self) -> ValuesView[_VT_co]: ...
          def __contains__(self, o: object) -> bool: ...

        class MutableMapping(Mapping[_KT, _VT], Generic[_KT, _VT]):
          @abstractmethod
          def __setitem__(self, k: _KT, v: _VT) -> None: ...
          @abstractmethod
          def __delitem__(self, v: _KT) -> None: ...

        class Awaitable(Protocol[_T_co]):
          def __await__(self) -> Generator[Any, None, _T_co]: ...
        class Coroutine(Awaitable[_V_co], Generic[_T_co, _T_contra, _V_co]): pass

        class AsyncGenerator(AsyncIterator[_T_co], Generic[_T_co, _T_contra]):
            @abstractmethod
            def __anext__(self) -> Awaitable[_T_co]:
                ...
            @abstractmethod
            def __aiter__(self) -> AsyncGenerator[_T_co, _T_contra]:
                ...

        @overload
        def cast(tp: Type[_T], obj: Any) -> _T: ...
        @overload
        def cast(tp: str, obj: Any) -> Any: ...
      |}
    |> Preprocessing.preprocess;
    parse
      ~qualifier:(Reference.create "abc")
      ~handle:"abc.pyi"
      {|
        _T = TypeVar('_T')
        class ABCMeta(type):
          def register(cls: ABCMeta, subclass: Type[_T]) -> Type[_T]: ...
        def abstractmethod(callable: _FuncT) -> _FuncT: ...
      |}
    |> Preprocessing.preprocess;
    Source.create ~qualifier:(Reference.create "unittest.mock") [];
    parse
      ~qualifier:Reference.empty
      ~handle:"builtins.pyi"
      builtins
    |> Preprocessing.preprocess;
    parse
      ~qualifier:(Reference.create "django.http")
      ~handle:"django/http.pyi"
      {|
        class Request:
          GET: typing.Dict[str, typing.Any] = ...
          POST: typing.Dict[str, typing.Any] = ...
      |}
    |> Preprocessing.preprocess;
    parse
      ~qualifier:(Reference.create "dataclasses")
      ~handle:"dataclasses.pyi"
      {|
        _T = typing.TypeVar('_T')
        class InitVar(typing.Generic[_T]): ...
      |};
    parse
      ~qualifier:(Reference.create "os")
      ~handle:"os.pyi"
      {|
        environ: typing.Dict[str, str] = ...
      |}
    |> Preprocessing.preprocess;
    parse
      ~qualifier:(Reference.create "subprocess")
      ~handle:"subprocess.pyi"
      {|
        def run(command, shell): ...
        def call(command, shell): ...
        def check_call(command, shell): ...
        def check_output(command, shell): ...
      |}
    |> Preprocessing.preprocess;
    parse
      ~qualifier:(Reference.create "abc")
      ~handle:"abc.pyi"
      {|
        from typing import Type, TypeVar
        _T = TypeVar('_T')
        class ABCMeta(type):
          def register(cls: ABCMeta, subclass: Type[_T]) -> Type[_T]: ...
        class ABC(metaclass=ABCMeta): ...
      |}
    |> Preprocessing.preprocess;
    parse
      ~qualifier:(Reference.create "enum")
      ~handle:"enum.pyi"
      {|
        from abc import ABCMeta
        _T = typing.TypeVar('_T')
        class EnumMeta(ABCMeta):
          def __members__(self: Type[_T]) -> Mapping[str, _T]: ...
          def __iter__(self: typing.Type[_T]) -> typing.Iterator[_T]: ...
        class Enum(metaclass=EnumMeta):
          def __new__(cls: typing.Type[_T], value: object) -> _T: ...
        class IntEnum(int, Enum):
          value = ...  # type: int
        if sys.version_info >= (3, 6):
          _auto_null: typing.Any
          class auto(IntFlag):
            value: typing.Any
          class Flag(Enum):
            pass
          class IntFlag(int, Flag):  # type: ignore
            pass
      |}
    |> Preprocessing.preprocess;
    parse
      ~qualifier:(Reference.create "threading")
      ~handle:"threading.pyi"
      {|
        class Thread:
          pass
      |}
    |> Preprocessing.preprocess;
    parse
      ~qualifier:(Reference.create "typing_extensions")
      ~handle:"typing_extensions.pyi"
      {|
        class _SpecialForm:
            def __getitem__(self, typeargs: Any) -> Any: ...
        Literal: _SpecialForm = ...
      |}
    |> Preprocessing.preprocess;
    parse
      ~qualifier:(Reference.create "collections")
      ~handle:"collections.pyi"
      {|
        from typing import (
            TypeVar,
            Generic,
            Dict,
            overload,
            List,
            Tuple,
            Any,
            Type,
            Optional,
            Union,
            Callable,
            Mapping,
            Iterable,
            Tuple,
        )

        _DefaultDictT = TypeVar("_DefaultDictT", bound=defaultdict)
        _KT = TypeVar("_KT")
        _VT = TypeVar("_VT")


        class defaultdict(Dict[_KT, _VT], Generic[_KT, _VT]):
            default_factory = ...  # type: Optional[Callable[[], _VT]]

            @overload
            def __init__(self, **kwargs: _VT) -> None:
                ...

            @overload
            def __init__(self, default_factory: Optional[Callable[[], _VT]]) -> None:
                ...

            @overload
            def __init__(
                self, default_factory: Optional[Callable[[], _VT]], **kwargs: _VT
            ) -> None:
                ...

            @overload
            def __init__(
                self, default_factory: Optional[Callable[[], _VT]], map: Mapping[_KT, _VT]
            ) -> None:
                ...

            @overload
            def __init__(
                self,
                default_factory: Optional[Callable[[], _VT]],
                map: Mapping[_KT, _VT],
                **kwargs: _VT
            ) -> None:
                ...

            @overload
            def __init__(
                self,
                default_factory: Optional[Callable[[], _VT]],
                iterable: Iterable[Tuple[_KT, _VT]],
            ) -> None:
                ...

            @overload
            def __init__(
                self,
                default_factory: Optional[Callable[[], _VT]],
                iterable: Iterable[Tuple[_KT, _VT]],
                **kwargs: _VT
            ) -> None:
                ...

            def __missing__(self, key: _KT) -> _VT:
                ...

            def copy(self: _DefaultDictT) -> _DefaultDictT:
                ...
      |}
    |> Preprocessing.preprocess;
    parse
      ~qualifier:(Reference.create "contextlib")
      ~handle:"contextlib.pyi"
      (* TODO (T41494196): Change the parameter and return type to AnyCallable *)
      {|
        from typing import Any
        def contextmanager(func: Any) -> Any:
            ...
        def asynccontextmanager(func: Any) -> Any:
            ...
      |}
    |> Preprocessing.preprocess;
    parse
      ~qualifier:(Reference.create "taint")
      ~handle:"taint.pyi"
      {|
        __global_sink: Any = ...
      |}
    |> Preprocessing.preprocess;
  ]


let populate ~configuration environment sources =
  Service.Environment.populate ~configuration ~scheduler:(Scheduler.mock ()) environment sources


let populate_shared_memory =
  Service.Environment.populate_shared_memory
    ~scheduler:(Scheduler.mock ())

let environment
    ?(sources = typeshed_stubs ())
    ?(configuration = mock_configuration)
    () =
  let environment =
    let environment = Environment.Builder.create () in
    Environment.handler environment
  in
  populate ~configuration environment sources;
  environment


let mock_signature = {
  Define.name = Reference.create "$empty";
  parameters = [];
  decorators = [];
  docstring = None;
  return_annotation = None;
  async = false;
  parent = None;
}


let mock_define = {
  Define.signature = mock_signature;
  body = [];
}


let resolution ?(sources = typeshed_stubs ()) ?(configuration = mock_configuration) () =
  let environment = environment ~sources () in
  add_defaults_to_environment ~configuration environment;
  TypeCheck.resolution environment ()


type test_update_environment_with_t = {
  qualifier: Reference.t;
  handle: string;
  source: string;
}
[@@deriving compare, eq, show]


let assert_errors
    ?(autogenerated = false)
    ?(debug = true)
    ?(strict = false)
    ?(declare = false)
    ?(infer = false)
    ?(show_error_traces = false)
    ?(concise = false)
    ?(qualifier = Reference.empty)
    ?(handle = "test.py")
    ?(update_environment_with = [])
    ~check
    source
    errors =
  Annotated.Class.AttributeCache.clear ();
  Resolution.Cache.clear ();
  let descriptions =
    let check source =
      let parse ~qualifier ~handle ~source =
        let metadata =
          Source.Metadata.create
            ~autogenerated
            ~debug
            ~declare
            ~ignore_lines:[]
            ~strict
            ~version:3
            ~number_of_lines:(-1)
            ()
        in
        parse ~handle ~qualifier source
        |> (fun source -> { source with Source.metadata })
        |> Preprocessing.preprocess
        |> Plugin.apply_to_ast
      in
      let source = parse ~qualifier ~handle ~source in
      let environment =
        let sources =
          source
          :: List.map
            update_environment_with
            ~f:(fun { qualifier; handle; source } -> parse ~qualifier ~handle ~source)
        in
        let environment =
          environment
            ~sources:(typeshed_stubs ())
            ~configuration:mock_configuration
            ()
        in
        Service.Environment.populate
          ~configuration:mock_configuration
          ~scheduler:(Scheduler.mock ())
          environment
          sources;
        environment
      in
      let configuration =
        Configuration.Analysis.create ~debug ~strict ~declare ~infer ()
      in
      check ~configuration ~environment ~source
    in
    List.map
      (check source)
      ~f:(fun error -> Error.description error ~show_error_traces ~concise)
  in
  assert_equal
    ~cmp:(List.equal ~equal:String.equal)
    ~printer:(String.concat ~sep:"\n")
    errors
    descriptions
