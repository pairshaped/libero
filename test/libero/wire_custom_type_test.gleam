/// Custom type wire roundtrip tests (ETF, BEAM-only).
///
/// Defines throwaway types covering every custom-type gotcha from
/// the git history (None/Nil, 0-arity, float fields, nested types)
/// and roundtrips them through encode → decode_call → coerce.
import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/option.{None, Some}
import libero/wire

// ============================================================================
// Test types
// ============================================================================

// 0-arity enum (bare atoms on BEAM)
pub type Status {
  Pending
  Active
  Cancelled
}

// N-arity record with mixed field types
pub type Point {
  Point(x: Float, y: Float)
}

// Record with mixed primitives
pub type Person {
  Person(name: String, age: Int, active: Bool)
}

// Multi-variant: mix of 0-arity and N-arity
pub type Shape {
  Circle(radius: Float)
  Rectangle(width: Float, height: Float)
  Unknown
}

// Nested custom type: record containing another record
pub type Label {
  Label(text: String, position: Point)
}

// Record with Option field
pub type Profile {
  Profile(name: String, nickname: option.Option(String))
}

// ============================================================================
// Helpers (same as wire_roundtrip_test)
// ============================================================================

fn roundtrip(value: a) -> Dynamic {
  let envelope = ffi_encode(coerce(#("shared/test", 0, coerce(value))))
  let assert Ok(#("shared/test", _request_id, rebuilt)) = wire.decode_call(envelope)
  rebuilt
}

@external(erlang, "libero_ffi", "encode")
fn ffi_encode(value: Dynamic) -> BitArray

@external(erlang, "gleam_stdlib", "identity")
fn coerce(value: a) -> Dynamic

@external(erlang, "gleam_stdlib", "identity")
fn unsafe_coerce(value: Dynamic) -> a

// ============================================================================
// 0-arity enum variants (bare atoms)
// ============================================================================

pub fn roundtrip_0_arity_pending_test() {
  let result: Status = unsafe_coerce(roundtrip(Pending))
  let assert Pending = result
}

pub fn roundtrip_0_arity_active_test() {
  let result: Status = unsafe_coerce(roundtrip(Active))
  let assert Active = result
}

pub fn roundtrip_0_arity_cancelled_test() {
  let result: Status = unsafe_coerce(roundtrip(Cancelled))
  let assert Cancelled = result
}

// ============================================================================
// N-arity records
// ============================================================================

pub fn roundtrip_point_test() {
  let result: Point = unsafe_coerce(roundtrip(Point(x: 1.5, y: -2.3)))
  let Point(x: x, y: y) = result
  let assert True = x >. 1.4 && x <. 1.6
  let assert True = y >. -2.4 && y <. -2.2
}

pub fn roundtrip_point_zero_test() {
  let result: Point = unsafe_coerce(roundtrip(Point(x: 0.0, y: 0.0)))
  let assert Point(x: 0.0, y: 0.0) = result
}

pub fn roundtrip_person_test() {
  let result: Person = unsafe_coerce(roundtrip(Person("Alice", 30, True)))
  let assert Person(name: "Alice", age: 30, active: True) = result
}

// ============================================================================
// Multi-variant (mix of 0-arity and N-arity)
// ============================================================================

pub fn roundtrip_shape_circle_test() {
  let result: Shape = unsafe_coerce(roundtrip(Circle(radius: 5.0)))
  let assert Circle(radius: r) = result
  let assert True = r >. 4.9 && r <. 5.1
}

pub fn roundtrip_shape_rectangle_test() {
  let result: Shape =
    unsafe_coerce(roundtrip(Rectangle(width: 10.0, height: 20.0)))
  let assert Rectangle(width: w, height: h) = result
  let assert True = w >. 9.9 && w <. 10.1
  let assert True = h >. 19.9 && h <. 20.1
}

pub fn roundtrip_shape_unknown_test() {
  let result: Shape = unsafe_coerce(roundtrip(Unknown))
  let assert Unknown = result
}

// ============================================================================
// Nested custom types
// ============================================================================

pub fn roundtrip_nested_label_test() {
  let label = Label(text: "origin", position: Point(x: 0.0, y: 0.0))
  let result: Label = unsafe_coerce(roundtrip(label))
  let assert Label(text: "origin", position: Point(x: 0.0, y: 0.0)) = result
}

pub fn roundtrip_nested_label_with_values_test() {
  let label = Label(text: "marker", position: Point(x: 3.14, y: -1.0))
  let result: Label = unsafe_coerce(roundtrip(label))
  let assert Label(text: "marker", position: pos) = result
  let assert True = pos.x >. 3.13 && pos.x <. 3.15
  let assert True = pos.y >. -1.1 && pos.y <. -0.9
}

// ============================================================================
// Custom types with Option fields
// ============================================================================

pub fn roundtrip_profile_with_nickname_test() {
  let result: Profile = unsafe_coerce(roundtrip(Profile("Alice", Some("Ali"))))
  let assert Profile(name: "Alice", nickname: Some("Ali")) = result
}

pub fn roundtrip_profile_without_nickname_test() {
  let result: Profile = unsafe_coerce(roundtrip(Profile("Bob", None)))
  let assert Profile(name: "Bob", nickname: None) = result
}

// ============================================================================
// Custom types inside containers
// ============================================================================

pub fn roundtrip_list_of_statuses_test() {
  let input = [Pending, Active, Cancelled, Active]
  let result: List(Status) = unsafe_coerce(roundtrip(input))
  let assert [Pending, Active, Cancelled, Active] = result
}

pub fn roundtrip_option_of_status_test() {
  let result: option.Option(Status) = unsafe_coerce(roundtrip(Some(Active)))
  let assert Some(Active) = result
}

pub fn roundtrip_option_none_status_test() {
  let result: option.Option(Status) = unsafe_coerce(roundtrip(None))
  let assert None = result
}

pub fn roundtrip_result_ok_point_test() {
  let input: Result(Point, String) = Ok(Point(x: 1.0, y: 2.0))
  let result: Result(Point, String) = unsafe_coerce(roundtrip(input))
  let assert Ok(Point(x: 1.0, y: 2.0)) = result
}

pub fn roundtrip_result_error_status_test() {
  let input: Result(String, Status) = Error(Cancelled)
  let result: Result(String, Status) = unsafe_coerce(roundtrip(input))
  let assert Error(Cancelled) = result
}

pub fn roundtrip_list_of_points_test() {
  let input = [Point(1.0, 2.0), Point(3.0, 4.0)]
  let result: List(Point) = unsafe_coerce(roundtrip(input))
  let assert [Point(x: 1.0, y: 2.0), Point(x: 3.0, y: 4.0)] = result
}

pub fn roundtrip_dict_of_status_test() {
  let input = dict.from_list([#("a", Pending), #("b", Active)])
  let result: dict.Dict(String, Status) = unsafe_coerce(roundtrip(input))
  let assert Ok(Pending) = dict.get(result, "a")
  let assert Ok(Active) = dict.get(result, "b")
}

// ============================================================================
// Complex nested: Result(List(Option(Custom)), Custom)
// ============================================================================

pub fn roundtrip_complex_nested_test() {
  let input: Result(List(option.Option(Status)), Shape) =
    Ok([Some(Pending), None, Some(Active)])
  let result: Result(List(option.Option(Status)), Shape) =
    unsafe_coerce(roundtrip(input))
  let assert Ok([Some(Pending), None, Some(Active)]) = result
}

pub fn roundtrip_complex_nested_error_test() {
  let input: Result(List(option.Option(Status)), Shape) = Error(Unknown)
  let result: Result(List(option.Option(Status)), Shape) =
    unsafe_coerce(roundtrip(input))
  let assert Error(Unknown) = result
}

// ============================================================================
// Float field gotcha: whole-number floats must stay as floats
// ============================================================================

pub fn roundtrip_point_whole_number_floats_test() {
  let result: Point = unsafe_coerce(roundtrip(Point(x: 2.0, y: 3.0)))
  let assert Point(x: 2.0, y: 3.0) = result
}

// ============================================================================
// List of multi-variant shapes
// ============================================================================

pub fn roundtrip_list_of_shapes_test() {
  let input = [Circle(1.0), Rectangle(2.0, 3.0), Unknown, Circle(4.5)]
  let result: List(Shape) = unsafe_coerce(roundtrip(input))
  let assert [Circle(_), Rectangle(_, _), Unknown, Circle(_)] = result
}

// ============================================================================
// Direct encode/decode (not via call envelope)
// ============================================================================

pub fn direct_roundtrip_status_test() {
  let result: Status = wire.decode(wire.encode(Active))
  let assert Active = result
}

pub fn direct_roundtrip_point_test() {
  let result: Point = wire.decode(wire.encode(Point(x: 1.0, y: 2.0)))
  let assert Point(x: 1.0, y: 2.0) = result
}

pub fn direct_roundtrip_nested_label_test() {
  let label = Label(text: "test", position: Point(x: 0.0, y: 0.0))
  let result: Label = wire.decode(wire.encode(label))
  let assert Label(text: "test", position: Point(x: 0.0, y: 0.0)) = result
}
