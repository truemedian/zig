//! Zig Intermediate Representation.
//!
//! Astgen.zig converts AST nodes to these untyped IR instructions. Next,
//! Sema.zig processes these into AIR.
//! The minimum amount of information needed to represent a list of ZIR instructions.
//! Once this structure is completed, it can be used to generate AIR, followed by
//! machine code, without any memory access into the AST tree token list, node list,
//! or source bytes. Exceptions include:
//!  * Compile errors, which may need to reach into these data structures to
//!    create a useful report.
//!  * In the future, possibly inline assembly, which needs to get parsed and
//!    handled by the codegen backend, and errors reported there. However for now,
//!    inline assembly is not an exception.

const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const BigIntConst = std.math.big.int.Const;
const BigIntMutable = std.math.big.int.Mutable;
const Ast = std.zig.Ast;

const Zir = @This();

instructions: std.MultiArrayList(Inst).Slice,
/// In order to store references to strings in fewer bytes, we copy all
/// string bytes into here. String bytes can be null. It is up to whomever
/// is referencing the data here whether they want to store both index and length,
/// thus allowing null bytes, or store only index, and use null-termination. The
/// `string_bytes` array is agnostic to either usage.
/// Index 0 is reserved for special cases.
string_bytes: []u8,
/// The meaning of this data is determined by `Inst.Tag` value.
/// The first few indexes are reserved. See `ExtraIndex` for the values.
extra: []u32,

/// The data stored at byte offset 0 when ZIR is stored in a file.
pub const Header = extern struct {
    instructions_len: u32,
    string_bytes_len: u32,
    extra_len: u32,
    /// We could leave this as padding, however it triggers a Valgrind warning because
    /// we read and write undefined bytes to the file system. This is harmless, but
    /// it's essentially free to have a zero field here and makes the warning go away,
    /// making it more likely that following Valgrind warnings will be taken seriously.
    unused: u32 = 0,
    stat_inode: std.fs.File.INode,
    stat_size: u64,
    stat_mtime: i128,
};

pub const ExtraIndex = enum(u32) {
    /// If this is 0, no compile errors. Otherwise there is a `CompileErrors`
    /// payload at this index.
    compile_errors,
    /// If this is 0, this file contains no imports. Otherwise there is a `Imports`
    /// payload at this index.
    imports,

    _,
};

fn ExtraData(comptime T: type) type {
    return struct { data: T, end: usize };
}

/// Returns the requested data, as well as the new index which is at the start of the
/// trailers for the object.
pub fn extraData(code: Zir, comptime T: type, index: usize) ExtraData(T) {
    const fields = @typeInfo(T).@"struct".fields;
    var i: usize = index;
    var result: T = undefined;
    inline for (fields) |field| {
        @field(result, field.name) = switch (field.type) {
            u32 => code.extra[i],

            Inst.Ref,
            Inst.Index,
            Inst.Declaration.Name,
            std.zig.SimpleComptimeReason,
            NullTerminatedString,
            // Ast.TokenIndex is missing because it is a u32.
            Ast.OptionalTokenIndex,
            Ast.Node.Index,
            Ast.Node.OptionalIndex,
            => @enumFromInt(code.extra[i]),

            Ast.TokenOffset,
            Ast.OptionalTokenOffset,
            Ast.Node.Offset,
            Ast.Node.OptionalOffset,
            => @enumFromInt(@as(i32, @bitCast(code.extra[i]))),

            Inst.Call.Flags,
            Inst.BuiltinCall.Flags,
            Inst.SwitchBlock.Bits,
            Inst.SwitchBlockErrUnion.Bits,
            Inst.FuncFancy.Bits,
            Inst.Declaration.Flags,
            Inst.Param.Type,
            Inst.Func.RetTy,
            => @bitCast(code.extra[i]),

            else => @compileError("bad field type"),
        };
        i += 1;
    }
    return .{
        .data = result,
        .end = i,
    };
}

pub const NullTerminatedString = enum(u32) {
    empty = 0,
    _,
};

/// Given an index into `string_bytes` returns the null-terminated string found there.
pub fn nullTerminatedString(code: Zir, index: NullTerminatedString) [:0]const u8 {
    const slice = code.string_bytes[@intFromEnum(index)..];
    return slice[0..std.mem.indexOfScalar(u8, slice, 0).? :0];
}

pub fn refSlice(code: Zir, start: usize, len: usize) []Inst.Ref {
    return @ptrCast(code.extra[start..][0..len]);
}

pub fn bodySlice(zir: Zir, start: usize, len: usize) []Inst.Index {
    return @ptrCast(zir.extra[start..][0..len]);
}

pub fn hasCompileErrors(code: Zir) bool {
    if (code.extra[@intFromEnum(ExtraIndex.compile_errors)] != 0) {
        return true;
    } else {
        assert(code.instructions.len != 0); // i.e. lowering did not fail
        return false;
    }
}

pub fn loweringFailed(code: Zir) bool {
    if (code.instructions.len == 0) {
        assert(code.hasCompileErrors());
        return true;
    } else {
        return false;
    }
}

pub fn deinit(code: *Zir, gpa: Allocator) void {
    code.instructions.deinit(gpa);
    gpa.free(code.string_bytes);
    gpa.free(code.extra);
    code.* = undefined;
}

/// These are untyped instructions generated from an Abstract Syntax Tree.
/// The data here is immutable because it is possible to have multiple
/// analyses on the same ZIR happening at the same time.
pub const Inst = struct {
    tag: Tag,
    data: Data,

    /// These names are used directly as the instruction names in the text format.
    /// See `data_field_map` for a list of which `Data` fields are used by each `Tag`.
    pub const Tag = enum(u8) {
        /// Arithmetic addition, asserts no integer overflow.
        /// Uses the `pl_node` union field. Payload is `Bin`.
        add,
        /// Twos complement wrapping integer addition.
        /// Uses the `pl_node` union field. Payload is `Bin`.
        addwrap,
        /// Saturating addition.
        /// Uses the `pl_node` union field. Payload is `Bin`.
        add_sat,
        /// The same as `add` except no safety check.
        add_unsafe,
        /// Arithmetic subtraction. Asserts no integer overflow.
        /// Uses the `pl_node` union field. Payload is `Bin`.
        sub,
        /// Twos complement wrapping integer subtraction.
        /// Uses the `pl_node` union field. Payload is `Bin`.
        subwrap,
        /// Saturating subtraction.
        /// Uses the `pl_node` union field. Payload is `Bin`.
        sub_sat,
        /// Arithmetic multiplication. Asserts no integer overflow.
        /// Uses the `pl_node` union field. Payload is `Bin`.
        mul,
        /// Twos complement wrapping integer multiplication.
        /// Uses the `pl_node` union field. Payload is `Bin`.
        mulwrap,
        /// Saturating multiplication.
        /// Uses the `pl_node` union field. Payload is `Bin`.
        mul_sat,
        /// Implements the `@divExact` builtin.
        /// Uses the `pl_node` union field with payload `Bin`.
        div_exact,
        /// Implements the `@divFloor` builtin.
        /// Uses the `pl_node` union field with payload `Bin`.
        div_floor,
        /// Implements the `@divTrunc` builtin.
        /// Uses the `pl_node` union field with payload `Bin`.
        div_trunc,
        /// Implements the `@mod` builtin.
        /// Uses the `pl_node` union field with payload `Bin`.
        mod,
        /// Implements the `@rem` builtin.
        /// Uses the `pl_node` union field with payload `Bin`.
        rem,
        /// Ambiguously remainder division or modulus. If the computation would possibly have
        /// a different value depending on whether the operation is remainder division or modulus,
        /// a compile error is emitted. Otherwise the computation is performed.
        /// Uses the `pl_node` union field. Payload is `Bin`.
        mod_rem,
        /// Integer shift-left. Zeroes are shifted in from the right hand side.
        /// Uses the `pl_node` union field. Payload is `Bin`.
        shl,
        /// Implements the `@shlExact` builtin.
        /// Uses the `pl_node` union field with payload `Bin`.
        shl_exact,
        /// Saturating shift-left.
        /// Uses the `pl_node` union field. Payload is `Bin`.
        shl_sat,
        /// Integer shift-right. Arithmetic or logical depending on the signedness of
        /// the integer type.
        /// Uses the `pl_node` union field. Payload is `Bin`.
        shr,
        /// Implements the `@shrExact` builtin.
        /// Uses the `pl_node` union field with payload `Bin`.
        shr_exact,

        /// Declares a parameter of the current function. Used for:
        /// * debug info
        /// * checking shadowing against declarations in the current namespace
        /// * parameter type expressions referencing other parameters
        /// These occur in the block outside a function body (the same block as
        /// contains the func instruction).
        /// Uses the `pl_tok` field. Token is the parameter name, payload is a `Param`.
        param,
        /// Same as `param` except the parameter is marked comptime.
        param_comptime,
        /// Same as `param` except the parameter is marked anytype.
        /// Uses the `str_tok` field. Token is the parameter name. String is the parameter name.
        param_anytype,
        /// Same as `param` except the parameter is marked both comptime and anytype.
        /// Uses the `str_tok` field. Token is the parameter name. String is the parameter name.
        param_anytype_comptime,
        /// Array concatenation. `a ++ b`
        /// Uses the `pl_node` union field. Payload is `Bin`.
        array_cat,
        /// Array multiplication `a ** b`
        /// Uses the `pl_node` union field. Payload is `ArrayMul`.
        array_mul,
        /// `[N]T` syntax. No source location provided.
        /// Uses the `pl_node` union field. Payload is `Bin`. lhs is length, rhs is element type.
        array_type,
        /// `[N:S]T` syntax. Source location is the array type expression node.
        /// Uses the `pl_node` union field. Payload is `ArrayTypeSentinel`.
        array_type_sentinel,
        /// `@Vector` builtin.
        /// Uses the `pl_node` union field with `Bin` payload.
        /// lhs is length, rhs is element type.
        vector_type,
        /// Given a pointer type, returns its element type. Reaches through any optional or error
        /// union types wrapping the pointer. Asserts that the underlying type is a pointer type.
        /// Returns generic poison if the element type is `anyopaque`.
        /// Uses the `un_node` field.
        elem_type,
        /// Given an indexable pointer (slice, many-ptr, single-ptr-to-array), returns its
        /// element type. Emits a compile error if the type is not an indexable pointer.
        /// Uses the `un_node` field.
        indexable_ptr_elem_type,
        /// Given a vector or array type, returns its element type.
        /// Uses the `un_node` field.
        vec_arr_elem_type,
        /// Given a pointer to an indexable object, returns the len property. This is
        /// used by for loops. This instruction also emits a for-loop specific compile
        /// error if the indexable object is not indexable.
        /// Uses the `un_node` field. The AST node is the for loop node.
        indexable_ptr_len,
        /// Create a `anyframe->T` type.
        /// Uses the `un_node` field.
        anyframe_type,
        /// Type coercion to the function's return type.
        /// Uses the `pl_node` field. Payload is `As`. AST node could be many things.
        as_node,
        /// Same as `as_node` but ignores runtime to comptime int error.
        as_shift_operand,
        /// Bitwise AND. `&`
        bit_and,
        /// Reinterpret the memory representation of a value as a different type.
        /// Uses the pl_node field with payload `Bin`.
        bitcast,
        /// Bitwise NOT. `~`
        /// Uses `un_node`.
        bit_not,
        /// Bitwise OR. `|`
        bit_or,
        /// A labeled block of code, which can return a value.
        /// Uses the `pl_node` union field. Payload is `Block`.
        block,
        /// Like `block`, but forces full evaluation of its contents at compile-time.
        /// Exited with `break_inline`.
        /// Uses the `pl_node` union field. Payload is `BlockComptime`.
        block_comptime,
        /// A list of instructions which are analyzed in the parent context, without
        /// generating a runtime block. Must terminate with an "inline" variant of
        /// a noreturn instruction.
        /// Uses the `pl_node` union field. Payload is `Block`.
        block_inline,
        /// This instruction may only ever appear in the list of declarations for a
        /// namespace type, e.g. within a `struct_decl` instruction. It represents a
        /// single source declaration (`const`/`var`/`fn`), containing the name,
        /// attributes, type, and value of the declaration.
        /// Uses the `declaration` union field. Payload is `Declaration`.
        declaration,
        /// Implements `suspend {...}`.
        /// Uses the `pl_node` union field. Payload is `Block`.
        suspend_block,
        /// Boolean NOT. See also `bit_not`.
        /// Uses the `un_node` field.
        bool_not,
        /// Short-circuiting boolean `and`. `lhs` is a boolean `Ref` and the other operand
        /// is a block, which is evaluated if `lhs` is `true`.
        /// Uses the `pl_node` union field. Payload is `BoolBr`.
        bool_br_and,
        /// Short-circuiting boolean `or`. `lhs` is a boolean `Ref` and the other operand
        /// is a block, which is evaluated if `lhs` is `false`.
        /// Uses the `pl_node` union field. Payload is `BoolBr`.
        bool_br_or,
        /// Return a value from a block.
        /// Uses the `break` union field.
        /// Uses the source information from previous instruction.
        @"break",
        /// Return a value from a block. This instruction is used as the terminator
        /// of a `block_inline`. It allows using the return value from `Sema.analyzeBody`.
        /// This instruction may also be used when it is known that there is only one
        /// break instruction in a block, and the target block is the parent.
        /// Uses the `break` union field.
        break_inline,
        /// Branch from within a switch case to the case specified by the operand.
        /// Uses the `break` union field. `block_inst` refers to a `switch_block` or `switch_block_ref`.
        switch_continue,
        /// Checks that comptime control flow does not happen inside a runtime block.
        /// Uses the `un_node` union field.
        check_comptime_control_flow,
        /// Function call.
        /// Uses the `pl_node` union field with payload `Call`.
        /// AST node is the function call.
        call,
        /// Function call using `a.b()` syntax.
        /// Uses the named field as the callee. If there is no such field, searches in the type for
        /// a decl matching the field name. The decl is resolved and we ensure that it's a function
        /// which can accept the object as the first parameter, with one pointer fixup. This
        /// function is then used as the callee, with the object as an implicit first parameter.
        /// Uses the `pl_node` union field with payload `FieldCall`.
        /// AST node is the function call.
        field_call,
        /// Implements the `@call` builtin.
        /// Uses the `pl_node` union field with payload `BuiltinCall`.
        /// AST node is the builtin call.
        builtin_call,
        /// `<`
        /// Uses the `pl_node` union field. Payload is `Bin`.
        cmp_lt,
        /// `<=`
        /// Uses the `pl_node` union field. Payload is `Bin`.
        cmp_lte,
        /// `==`
        /// Uses the `pl_node` union field. Payload is `Bin`.
        cmp_eq,
        /// `>=`
        /// Uses the `pl_node` union field. Payload is `Bin`.
        cmp_gte,
        /// `>`
        /// Uses the `pl_node` union field. Payload is `Bin`.
        cmp_gt,
        /// `!=`
        /// Uses the `pl_node` union field. Payload is `Bin`.
        cmp_neq,
        /// Conditional branch. Splits control flow based on a boolean condition value.
        /// Uses the `pl_node` union field. AST node is an if, while, for, etc.
        /// Payload is `CondBr`.
        condbr,
        /// Same as `condbr`, except the condition is coerced to a comptime value, and
        /// only the taken branch is analyzed. The then block and else block must
        /// terminate with an "inline" variant of a noreturn instruction.
        condbr_inline,
        /// Given an operand which is an error union, splits control flow. In
        /// case of error, control flow goes into the block that is part of this
        /// instruction, which is guaranteed to end with a return instruction
        /// and never breaks out of the block.
        /// In the case of non-error, control flow proceeds to the next instruction
        /// after the `try`, with the result of this instruction being the unwrapped
        /// payload value, as if `err_union_payload_unsafe` was executed on the operand.
        /// Uses the `pl_node` union field. Payload is `Try`.
        @"try",
        /// Same as `try` except the operand is a pointer and the result is a pointer.
        try_ptr,
        /// An error set type definition. Contains a list of field names.
        /// Uses the `pl_node` union field. Payload is `ErrorSetDecl`.
        error_set_decl,
        /// Declares the beginning of a statement. Used for debug info.
        /// Uses the `dbg_stmt` union field. The line and column are offset
        /// from the parent declaration.
        dbg_stmt,
        /// Marks a variable declaration. Used for debug info.
        /// Uses the `str_op` union field. The string is the local variable name,
        /// and the operand is the pointer to the variable's location. The local
        /// may be a const or a var.
        dbg_var_ptr,
        /// Same as `dbg_var_ptr` but the local is always a const and the operand
        /// is the local's value.
        dbg_var_val,
        /// Uses a name to identify a Decl and takes a pointer to it.
        /// Uses the `str_tok` union field.
        decl_ref,
        /// Uses a name to identify a Decl and uses it as a value.
        /// Uses the `str_tok` union field.
        decl_val,
        /// Load the value from a pointer. Assumes `x.*` syntax.
        /// Uses `un_node` field. AST node is the `x.*` syntax.
        load,
        /// Arithmetic division. Asserts no integer overflow.
        /// Uses the `pl_node` union field. Payload is `Bin`.
        div,
        /// Given a pointer to an array, slice, or pointer, returns a pointer to the element at
        /// the provided index.
        /// Uses the `pl_node` union field. AST node is a[b] syntax. Payload is `Bin`.
        elem_ptr_node,
        /// Same as `elem_ptr_node` but used only for for loop.
        /// Uses the `pl_node` union field. AST node is the condition of a for loop.
        /// Payload is `Bin`.
        /// No OOB safety check is emitted.
        elem_ptr,
        /// Given an array, slice, or pointer, returns the element at the provided index.
        /// Uses the `pl_node` union field. AST node is a[b] syntax. Payload is `Bin`.
        elem_val_node,
        /// Same as `elem_val_node` but used only for for loop.
        /// Uses the `pl_node` union field. AST node is the condition of a for loop.
        /// Payload is `Bin`.
        /// No OOB safety check is emitted.
        elem_val,
        /// Same as `elem_val` but takes the index as an immediate value.
        /// No OOB safety check is emitted. A prior instruction must validate this operation.
        /// Uses the `elem_val_imm` union field.
        elem_val_imm,
        /// Emits a compile error if the operand is not `void`.
        /// Uses the `un_node` field.
        ensure_result_used,
        /// Emits a compile error if an error is ignored.
        /// Uses the `un_node` field.
        ensure_result_non_error,
        /// Emits a compile error error union payload is not void.
        ensure_err_union_payload_void,
        /// Create a `E!T` type.
        /// Uses the `pl_node` field with `Bin` payload.
        error_union_type,
        /// `error.Foo` syntax. Uses the `str_tok` field of the Data union.
        error_value,
        /// Implements the `@export` builtin function.
        /// Uses the `pl_node` union field. Payload is `Export`.
        @"export",
        /// Given a pointer to a struct or object that contains virtual fields, returns a pointer
        /// to the named field. The field name is stored in string_bytes. Used by a.b syntax.
        /// Uses `pl_node` field. The AST node is the a.b syntax. Payload is Field.
        field_ptr,
        /// Given a struct or object that contains virtual fields, returns the named field.
        /// The field name is stored in string_bytes. Used by a.b syntax.
        /// This instruction also accepts a pointer.
        /// Uses `pl_node` field. The AST node is the a.b syntax. Payload is Field.
        field_val,
        /// Given a pointer to a struct or object that contains virtual fields, returns a pointer
        /// to the named field. The field name is a comptime instruction. Used by @field.
        /// Uses `pl_node` field. The AST node is the builtin call. Payload is FieldNamed.
        field_ptr_named,
        /// Given a struct or object that contains virtual fields, returns the named field.
        /// The field name is a comptime instruction. Used by @field.
        /// Uses `pl_node` field. The AST node is the builtin call. Payload is FieldNamed.
        field_val_named,
        /// Returns a function type, or a function instance, depending on whether
        /// the body_len is 0. Calling convention is auto.
        /// Uses the `pl_node` union field. `payload_index` points to a `Func`.
        func,
        /// Same as `func` but has an inferred error set.
        func_inferred,
        /// Represents a function declaration or function prototype, depending on
        /// whether body_len is 0.
        /// Uses the `pl_node` union field. `payload_index` points to a `FuncFancy`.
        func_fancy,
        /// Implements the `@import` builtin.
        /// Uses the `pl_tok` field.
        import,
        /// Integer literal that fits in a u64. Uses the `int` union field.
        int,
        /// Arbitrary sized integer literal. Uses the `str` union field.
        int_big,
        /// A float literal that fits in a f64. Uses the float union value.
        float,
        /// A float literal that fits in a f128. Uses the `pl_node` union value.
        /// Payload is `Float128`.
        float128,
        /// Make an integer type out of signedness and bit count.
        /// Payload is `int_type`
        int_type,
        /// Return a boolean false if an optional is null. `x != null`
        /// Uses the `un_node` field.
        is_non_null,
        /// Return a boolean false if an optional is null. `x.* != null`
        /// Uses the `un_node` field.
        is_non_null_ptr,
        /// Return a boolean false if value is an error
        /// Uses the `un_node` field.
        is_non_err,
        /// Return a boolean false if dereferenced pointer is an error
        /// Uses the `un_node` field.
        is_non_err_ptr,
        /// Same as `is_non_er` but doesn't validate that the type can be an error.
        /// Uses the `un_node` field.
        ret_is_non_err,
        /// A labeled block of code that loops forever. At the end of the body will have either
        /// a `repeat` instruction or a `repeat_inline` instruction.
        /// Uses the `pl_node` field. The AST node is either a for loop or while loop.
        /// This ZIR instruction is needed because AIR does not (yet?) match ZIR, and Sema
        /// needs to emit more than 1 AIR block for this instruction.
        /// The payload is `Block`.
        loop,
        /// Sends runtime control flow back to the beginning of the current block.
        /// Uses the `node` field.
        repeat,
        /// Sends comptime control flow back to the beginning of the current block.
        /// Uses the `node` field.
        repeat_inline,
        /// Asserts that all the lengths provided match. Used to build a for loop.
        /// Return value is the length as a usize.
        /// Uses the `pl_node` field with payload `MultiOp`.
        /// There are two items for each AST node inside the for loop condition.
        /// If both items in a pair are `.none`, then this node is an unbounded range.
        /// If only the second item in a pair is `.none`, then the first is an indexable.
        /// Otherwise, the node is a bounded range `a..b`, with the items being `a` and `b`.
        /// Illegal behaviors:
        ///  * If all lengths are unbounded ranges (always a compile error).
        ///  * If any two lengths do not match each other.
        for_len,
        /// Merge two error sets into one, `E1 || E2`.
        /// Uses the `pl_node` field with payload `Bin`.
        merge_error_sets,
        /// Turns an R-Value into a const L-Value. In other words, it takes a value,
        /// stores it in a memory location, and returns a const pointer to it. If the value
        /// is `comptime`, the memory location is global static constant data. Otherwise,
        /// the memory location is in the stack frame, local to the scope containing the
        /// instruction.
        /// Uses the `un_tok` union field.
        ref,
        /// Sends control flow back to the function's callee.
        /// Includes an operand as the return value.
        /// Includes an AST node source location.
        /// Uses the `un_node` union field.
        ret_node,
        /// Sends control flow back to the function's callee.
        /// The operand is a `ret_ptr` instruction, where the return value can be found.
        /// Includes an AST node source location.
        /// Uses the `un_node` union field.
        ret_load,
        /// Sends control flow back to the function's callee.
        /// Includes an operand as the return value.
        /// Includes a token source location.
        /// Uses the `un_tok` union field.
        ret_implicit,
        /// Sends control flow back to the function's callee.
        /// The return operand is `error.foo` where `foo` is given by the string.
        /// If the current function has an inferred error set, the error given by the
        /// name is added to it.
        /// Uses the `str_tok` union field.
        ret_err_value,
        /// A string name is provided which is an anonymous error set value.
        /// If the current function has an inferred error set, the error given by the
        /// name is added to it.
        /// Results in the error code. Note that control flow is not diverted with
        /// this instruction; a following 'ret' instruction will do the diversion.
        /// Uses the `str_tok` union field.
        ret_err_value_code,
        /// Obtains a pointer to the return value.
        /// Uses the `node` union field.
        ret_ptr,
        /// Obtains the return type of the in-scope function.
        /// Uses the `node` union field.
        ret_type,
        /// Create a pointer type which can have a sentinel, alignment, address space, and/or bit range.
        /// Uses the `ptr_type` union field.
        ptr_type,
        /// Slice operation `lhs[rhs..]`. No sentinel and no end offset.
        /// Returns a pointer to the subslice.
        /// Uses the `pl_node` field. AST node is the slice syntax. Payload is `SliceStart`.
        slice_start,
        /// Slice operation `array_ptr[start..end]`. No sentinel.
        /// Returns a pointer to the subslice.
        /// Uses the `pl_node` field. AST node is the slice syntax. Payload is `SliceEnd`.
        slice_end,
        /// Slice operation `array_ptr[start..end:sentinel]`.
        /// Returns a pointer to the subslice.
        /// Uses the `pl_node` field. AST node is the slice syntax. Payload is `SliceSentinel`.
        slice_sentinel,
        /// Slice operation `array_ptr[start..][0..len]`. Optional sentinel.
        /// Returns a pointer to the subslice.
        /// Uses the `pl_node` field. AST node is the slice syntax. Payload is `SliceLength`.
        slice_length,
        /// Given a value which is a pointer to the LHS of a slice operation, return the sentinel
        /// type, used as the result type of the slice sentinel (i.e. `s` in `lhs[a..b :s]`).
        /// Uses the `un_node` field. AST node is the slice syntax. Operand is `lhs`.
        slice_sentinel_ty,
        /// Same as `store` except provides a source location.
        /// Uses the `pl_node` union field. Payload is `Bin`.
        store_node,
        /// Same as `store_node` but the type of the value being stored will be
        /// used to infer the pointer type of an `alloc_inferred`.
        /// Uses the `pl_node` union field. Payload is `Bin`.
        store_to_inferred_ptr,
        /// String Literal. Makes an anonymous Decl and then takes a pointer to it.
        /// Uses the `str` union field.
        str,
        /// Arithmetic negation. Asserts no integer overflow.
        /// Same as sub with a lhs of 0, split into a separate instruction to save memory.
        /// Uses `un_node`.
        negate,
        /// Twos complement wrapping integer negation.
        /// Same as subwrap with a lhs of 0, split into a separate instruction to save memory.
        /// Uses `un_node`.
        negate_wrap,
        /// Returns the type of a value.
        /// Uses the `un_node` field.
        typeof,
        /// Implements `@TypeOf` for one operand.
        /// Uses the `pl_node` field. Payload is `Block`.
        typeof_builtin,
        /// Given a value, look at the type of it, which must be an integer type.
        /// Returns the integer type for the RHS of a shift operation.
        /// Uses the `un_node` field.
        typeof_log2_int_type,
        /// Asserts control-flow will not reach this instruction (`unreachable`).
        /// Uses the `@"unreachable"` union field.
        @"unreachable",
        /// Bitwise XOR. `^`
        /// Uses the `pl_node` union field. Payload is `Bin`.
        xor,
        /// Create an optional type '?T'
        /// Uses the `un_node` field.
        optional_type,
        /// ?T => T with safety.
        /// Given an optional value, returns the payload value, with a safety check that
        /// the value is non-null. Used for `orelse`, `if` and `while`.
        /// Uses the `un_node` field.
        optional_payload_safe,
        /// ?T => T without safety.
        /// Given an optional value, returns the payload value. No safety checks.
        /// Uses the `un_node` field.
        optional_payload_unsafe,
        /// *?T => *T with safety.
        /// Given a pointer to an optional value, returns a pointer to the payload value,
        /// with a safety check that the value is non-null. Used for `orelse`, `if` and `while`.
        /// Uses the `un_node` field.
        optional_payload_safe_ptr,
        /// *?T => *T without safety.
        /// Given a pointer to an optional value, returns a pointer to the payload value.
        /// No safety checks.
        /// Uses the `un_node` field.
        optional_payload_unsafe_ptr,
        /// E!T => T without safety.
        /// Given an error union value, returns the payload value. No safety checks.
        /// Uses the `un_node` field.
        err_union_payload_unsafe,
        /// *E!T => *T without safety.
        /// Given a pointer to a error union value, returns a pointer to the payload value.
        /// No safety checks.
        /// Uses the `un_node` field.
        err_union_payload_unsafe_ptr,
        /// E!T => E without safety.
        /// Given an error union value, returns the error code. No safety checks.
        /// Uses the `un_node` field.
        err_union_code,
        /// *E!T => E without safety.
        /// Given a pointer to an error union value, returns the error code. No safety checks.
        /// Uses the `un_node` field.
        err_union_code_ptr,
        /// An enum literal. Uses the `str_tok` union field.
        enum_literal,
        /// A decl literal. This is similar to `field`, but unwraps error unions and optionals,
        /// and coerces the result to the given type.
        /// Uses the `pl_node` union field. Payload is `Field`.
        decl_literal,
        /// The same as `decl_literal`, but the coercion is omitted. This is used for decl literal
        /// function call syntax, i.e. `.foo()`.
        /// Uses the `pl_node` union field. Payload is `Field`.
        decl_literal_no_coerce,
        /// A switch expression. Uses the `pl_node` union field.
        /// AST node is the switch, payload is `SwitchBlock`.
        switch_block,
        /// A switch expression. Uses the `pl_node` union field.
        /// AST node is the switch, payload is `SwitchBlock`. Operand is a pointer.
        switch_block_ref,
        /// A switch on an error union `a catch |err| switch (err) {...}`.
        /// Uses the `pl_node` union field. AST node is the `catch`, payload is `SwitchBlockErrUnion`.
        switch_block_err_union,
        /// Check that operand type supports the dereference operand (.*).
        /// Uses the `un_node` field.
        validate_deref,
        /// Check that the operand's type is an array or tuple with the given number of elements.
        /// Uses the `pl_node` field. Payload is `ValidateDestructure`.
        validate_destructure,
        /// Given a struct or union, and a field name as a Ref,
        /// returns the field type. Uses the `pl_node` field. Payload is `FieldTypeRef`.
        field_type_ref,
        /// Given a pointer, initializes all error unions and optionals in the pointee to payloads,
        /// returning the base payload pointer. For instance, converts *E!?T into a valid *T
        /// (clobbering any existing error or null value).
        /// Uses the `un_node` field.
        opt_eu_base_ptr_init,
        /// Coerce a given value such that when a reference is taken, the resulting pointer will be
        /// coercible to the given type. For instance, given a value of type 'u32' and the pointer
        /// type '*u64', coerces the value to a 'u64'. Asserts that the type is a pointer type.
        /// Uses the `pl_node` field. Payload is `Bin`.
        /// LHS is the pointer type, RHS is the value.
        coerce_ptr_elem_ty,
        /// Given a type, validate that it is a pointer type suitable for return from the address-of
        /// operator. Emit a compile error if not.
        /// Uses the `un_tok` union field. Token is the `&` operator. Operand is the type.
        validate_ref_ty,
        /// Given a value, check whether it is a valid local constant in this scope.
        /// In a runtime scope, this is always a nop.
        /// In a comptime scope, raises a compile error if the value is runtime-known.
        /// Result is always void.
        /// Uses the `un_node` union field. Node is the initializer. Operand is the initializer value.
        validate_const,

        // The following tags all relate to struct initialization expressions.

        /// A struct literal with a specified explicit type, with no fields.
        /// Uses the `un_node` field.
        struct_init_empty,
        /// An anonymous struct literal with a known result type, with no fields.
        /// Uses the `un_node` field.
        struct_init_empty_result,
        /// An anonymous struct literal with no fields, returned by reference, with a known result
        /// type for the pointer. Asserts that the type is a pointer.
        /// Uses the `un_node` field.
        struct_init_empty_ref_result,
        /// Struct initialization without a type. Creates a value of an anonymous struct type.
        /// Uses the `pl_node` field. Payload is `StructInitAnon`.
        struct_init_anon,
        /// Finalizes a typed struct or union initialization, performs validation, and returns the
        /// struct or union value. The given type must be validated prior to this instruction, using
        /// `validate_struct_init_ty` or `validate_struct_init_result_ty`. If the given type is
        /// generic poison, this is downgraded to an anonymous initialization.
        /// Uses the `pl_node` field. Payload is `StructInit`.
        struct_init,
        /// Struct initialization syntax, make the result a pointer. Equivalent to `struct_init`
        /// followed by `ref` - this ZIR tag exists as an optimization for a common pattern.
        /// Uses the `pl_node` field. Payload is `StructInit`.
        struct_init_ref,
        /// Checks that the type supports struct init syntax. Always returns void.
        /// Uses the `un_node` field.
        validate_struct_init_ty,
        /// Like `validate_struct_init_ty`, but additionally accepts types which structs coerce to.
        /// Used on the known result type of a struct init expression. Always returns void.
        /// Uses the `un_node` field.
        validate_struct_init_result_ty,
        /// Given a set of `struct_init_field_ptr` instructions, assumes they are all part of a
        /// struct initialization expression, and emits compile errors for duplicate fields as well
        /// as missing fields, if applicable.
        /// This instruction asserts that there is at least one struct_init_field_ptr instruction,
        /// because it must use one of them to find out the struct type.
        /// Uses the `pl_node` field. Payload is `Block`.
        validate_ptr_struct_init,
        /// Given a type being used for a struct initialization expression, returns the type of the
        /// field with the given name.
        /// Uses the `pl_node` field. Payload is `FieldType`.
        struct_init_field_type,
        /// Given a pointer being used as the result pointer of a struct initialization expression,
        /// return a pointer to the field of the given name.
        /// Uses the `pl_node` field. The AST node is the field initializer. Payload is Field.
        struct_init_field_ptr,

        // The following tags all relate to array initialization expressions.

        /// Array initialization without a type. Creates a value of a tuple type.
        /// Uses the `pl_node` field. Payload is `MultiOp`.
        array_init_anon,
        /// Array initialization syntax with a known type. The given type must be validated prior to
        /// this instruction, using some `validate_array_init_*_ty` instruction.
        /// Uses the `pl_node` field. Payload is `MultiOp`, where the first operand is the type.
        array_init,
        /// Array initialization syntax, make the result a pointer. Equivalent to `array_init`
        /// followed by `ref`- this ZIR tag exists as an optimization for a common pattern.
        /// Uses the `pl_node` field. Payload is `MultiOp`, where the first operand is the type.
        array_init_ref,
        /// Checks that the type supports array init syntax. Always returns void.
        /// Uses the `pl_node` field. Payload is `ArrayInit`.
        validate_array_init_ty,
        /// Like `validate_array_init_ty`, but additionally accepts types which arrays coerce to.
        /// Used on the known result type of an array init expression. Always returns void.
        /// Uses the `pl_node` field. Payload is `ArrayInit`.
        validate_array_init_result_ty,
        /// Given a pointer or slice type and an element count, return the expected type of an array
        /// initializer such that a pointer to the initializer has the given pointer type, checking
        /// that this type supports array init syntax and emitting a compile error if not. Preserves
        /// error union and optional wrappers on the array type, if any.
        /// Asserts that the given type is a pointer or slice type.
        /// Uses the `pl_node` field. Payload is `ArrayInitRefTy`.
        validate_array_init_ref_ty,
        /// Given a set of `array_init_elem_ptr` instructions, assumes they are all part of an array
        /// initialization expression, and emits a compile error if the number of elements does not
        /// match the array type.
        /// This instruction asserts that there is at least one `array_init_elem_ptr` instruction,
        /// because it must use one of them to find out the array type.
        /// Uses the `pl_node` field. Payload is `Block`.
        validate_ptr_array_init,
        /// Given a type being used for an array initialization expression, returns the type of the
        /// element at the given index.
        /// Uses the `bin` union field. lhs is the indexable type, rhs is the index.
        array_init_elem_type,
        /// Given a pointer being used as the result pointer of an array initialization expression,
        /// return a pointer to the element at the given index.
        /// Uses the `pl_node` union field. AST node is an element inside array initialization
        /// syntax. Payload is `ElemPtrImm`.
        array_init_elem_ptr,

        /// Implements the `@unionInit` builtin.
        /// Uses the `pl_node` field. Payload is `UnionInit`.
        union_init,
        /// Implements the `@typeInfo` builtin. Uses `un_node`.
        type_info,
        /// Implements the `@sizeOf` builtin. Uses `un_node`.
        size_of,
        /// Implements the `@bitSizeOf` builtin. Uses `un_node`.
        bit_size_of,

        /// Implement builtin `@intFromPtr`. Uses `un_node`.
        /// Convert a pointer to a `usize` integer.
        int_from_ptr,
        /// Emit an error message and fail compilation.
        /// Uses the `un_node` field.
        compile_error,
        /// Changes the maximum number of backwards branches that compile-time
        /// code execution can use before giving up and making a compile error.
        /// Uses the `un_node` union field.
        set_eval_branch_quota,
        /// Converts an enum value into an integer. Resulting type will be the tag type
        /// of the enum. Uses `un_node`.
        int_from_enum,
        /// Implement builtin `@alignOf`. Uses `un_node`.
        align_of,
        /// Implement builtin `@intFromBool`. Uses `un_node`.
        int_from_bool,
        /// Implement builtin `@embedFile`. Uses `un_node`.
        embed_file,
        /// Implement builtin `@errorName`. Uses `un_node`.
        error_name,
        /// Implement builtin `@panic`. Uses `un_node`.
        panic,
        /// Implements `@trap`.
        /// Uses the `node` field.
        trap,
        /// Implement builtin `@setRuntimeSafety`. Uses `un_node`.
        set_runtime_safety,
        /// Implement builtin `@sqrt`. Uses `un_node`.
        sqrt,
        /// Implement builtin `@sin`. Uses `un_node`.
        sin,
        /// Implement builtin `@cos`. Uses `un_node`.
        cos,
        /// Implement builtin `@tan`. Uses `un_node`.
        tan,
        /// Implement builtin `@exp`. Uses `un_node`.
        exp,
        /// Implement builtin `@exp2`. Uses `un_node`.
        exp2,
        /// Implement builtin `@log`. Uses `un_node`.
        log,
        /// Implement builtin `@log2`. Uses `un_node`.
        log2,
        /// Implement builtin `@log10`. Uses `un_node`.
        log10,
        /// Implement builtin `@abs`. Uses `un_node`.
        abs,
        /// Implement builtin `@floor`. Uses `un_node`.
        floor,
        /// Implement builtin `@ceil`. Uses `un_node`.
        ceil,
        /// Implement builtin `@trunc`. Uses `un_node`.
        trunc,
        /// Implement builtin `@round`. Uses `un_node`.
        round,
        /// Implement builtin `@tagName`. Uses `un_node`.
        tag_name,
        /// Implement builtin `@typeName`. Uses `un_node`.
        type_name,
        /// Implement builtin `@Frame`. Uses `un_node`.
        frame_type,

        /// Implements the `@intFromFloat` builtin.
        /// Uses `pl_node` with payload `Bin`. `lhs` is dest type, `rhs` is operand.
        int_from_float,
        /// Implements the `@floatFromInt` builtin.
        /// Uses `pl_node` with payload `Bin`. `lhs` is dest type, `rhs` is operand.
        float_from_int,
        /// Implements the `@ptrFromInt` builtin.
        /// Uses `pl_node` with payload `Bin`. `lhs` is dest type, `rhs` is operand.
        ptr_from_int,
        /// Converts an integer into an enum value.
        /// Uses `pl_node` with payload `Bin`. `lhs` is dest type, `rhs` is operand.
        enum_from_int,
        /// Convert a larger float type to any other float type, possibly causing
        /// a loss of precision.
        /// Uses the `pl_node` field. AST is the `@floatCast` syntax.
        /// Payload is `Bin` with lhs as the dest type, rhs the operand.
        float_cast,
        /// Implements the `@intCast` builtin.
        /// Uses `pl_node` with payload `Bin`. `lhs` is dest type, `rhs` is operand.
        /// Convert an integer value to another integer type, asserting that the destination type
        /// can hold the same mathematical value.
        int_cast,
        /// Implements the `@ptrCast` builtin.
        /// Uses `pl_node` with payload `Bin`. `lhs` is dest type, `rhs` is operand.
        /// Not every `@ptrCast` will correspond to this instruction - see also
        /// `ptr_cast_full` in `Extended`.
        ptr_cast,
        /// Implements the `@truncate` builtin.
        /// Uses `pl_node` with payload `Bin`. `lhs` is dest type, `rhs` is operand.
        truncate,

        /// Implements the `@hasDecl` builtin.
        /// Uses the `pl_node` union field. Payload is `Bin`.
        has_decl,
        /// Implements the `@hasField` builtin.
        /// Uses the `pl_node` union field. Payload is `Bin`.
        has_field,

        /// Implements the `@clz` builtin. Uses the `un_node` union field.
        clz,
        /// Implements the `@ctz` builtin. Uses the `un_node` union field.
        ctz,
        /// Implements the `@popCount` builtin. Uses the `un_node` union field.
        pop_count,
        /// Implements the `@byteSwap` builtin. Uses the `un_node` union field.
        byte_swap,
        /// Implements the `@bitReverse` builtin. Uses the `un_node` union field.
        bit_reverse,

        /// Implements the `@bitOffsetOf` builtin.
        /// Uses the `pl_node` union field with payload `Bin`.
        bit_offset_of,
        /// Implements the `@offsetOf` builtin.
        /// Uses the `pl_node` union field with payload `Bin`.
        offset_of,
        /// Implements the `@splat` builtin.
        /// Uses the `pl_node` union field with payload `Bin`.
        splat,
        /// Implements the `@reduce` builtin.
        /// Uses the `pl_node` union field with payload `Bin`.
        reduce,
        /// Implements the `@shuffle` builtin.
        /// Uses the `pl_node` union field with payload `Shuffle`.
        shuffle,
        /// Implements the `@atomicLoad` builtin.
        /// Uses the `pl_node` union field with payload `AtomicLoad`.
        atomic_load,
        /// Implements the `@atomicRmw` builtin.
        /// Uses the `pl_node` union field with payload `AtomicRmw`.
        atomic_rmw,
        /// Implements the `@atomicStore` builtin.
        /// Uses the `pl_node` union field with payload `AtomicStore`.
        atomic_store,
        /// Implements the `@mulAdd` builtin.
        /// Uses the `pl_node` union field with payload `MulAdd`.
        /// The addend communicates the type of the builtin.
        /// The mulends need to be coerced to the same type.
        mul_add,
        /// Implements the `@memcpy` builtin.
        /// Uses the `pl_node` union field with payload `Bin`.
        memcpy,
        /// Implements the `@memmove` builtin.
        /// Uses the `pl_node` union field with payload `Bin`.
        memmove,
        /// Implements the `@memset` builtin.
        /// Uses the `pl_node` union field with payload `Bin`.
        memset,
        /// Implements the `@min` builtin for 2 args.
        /// Uses the `pl_node` union field with payload `Bin`
        min,
        /// Implements the `@max` builtin for 2 args.
        /// Uses the `pl_node` union field with payload `Bin`
        max,
        /// Implements the `@cImport` builtin.
        /// Uses the `pl_node` union field with payload `Block`.
        c_import,

        /// Allocates stack local memory.
        /// Uses the `un_node` union field. The operand is the type of the allocated object.
        /// The node source location points to a var decl node.
        /// A `make_ptr_const` instruction should be used once the value has
        /// been stored to the allocation. To ensure comptime value detection
        /// functions, there are some restrictions on how this pointer should be
        /// used prior to the `make_ptr_const` instruction: no pointer derived
        /// from this `alloc` may be returned from a block or stored to another
        /// address. In other words, it must be trivial to determine whether any
        /// given pointer derives from this one.
        alloc,
        /// Same as `alloc` except mutable. As such, `make_ptr_const` need not be used,
        /// and there are no restrictions on the usage of the pointer.
        alloc_mut,
        /// Allocates comptime-mutable memory.
        /// Uses the `un_node` union field. The operand is the type of the allocated object.
        /// The node source location points to a var decl node.
        alloc_comptime_mut,
        /// Same as `alloc` except the type is inferred.
        /// Uses the `node` union field.
        alloc_inferred,
        /// Same as `alloc_inferred` except mutable.
        alloc_inferred_mut,
        /// Allocates comptime const memory.
        /// Uses the `node` union field. The type of the allocated object is inferred.
        /// The node source location points to a var decl node.
        alloc_inferred_comptime,
        /// Same as `alloc_comptime_mut` except the type is inferred.
        alloc_inferred_comptime_mut,
        /// Each `store_to_inferred_ptr` puts the type of the stored value into a set,
        /// and then `resolve_inferred_alloc` triggers peer type resolution on the set.
        /// The operand is a `alloc_inferred` or `alloc_inferred_mut` instruction, which
        /// is the allocation that needs to have its type inferred.
        /// Results in the final resolved pointer. The `alloc_inferred[_comptime][_mut]`
        /// instruction should never be referred to after this instruction.
        /// Uses the `un_node` field. The AST node is the var decl.
        resolve_inferred_alloc,
        /// Turns a pointer coming from an `alloc` or `Extended.alloc` into a constant
        /// version of the same pointer. For inferred allocations this is instead implicitly
        /// handled by the `resolve_inferred_alloc` instruction.
        /// Uses the `un_node` union field.
        make_ptr_const,

        /// Implements `resume` syntax. Uses `un_node` field.
        @"resume",

        /// A defer statement.
        /// Uses the `defer` union field.
        @"defer",
        /// An errdefer statement with a code.
        /// Uses the `err_defer_code` union field.
        defer_err_code,

        /// Requests that Sema update the saved error return trace index for the enclosing
        /// block, if the operand is .none or of an error/error-union type.
        /// Uses the `save_err_ret_index` field.
        save_err_ret_index,
        /// Specialized form of `Extended.restore_err_ret_index`.
        /// Unconditionally restores the error return index to its last saved state
        /// in the block referred to by `operand`. If `operand` is `none`, restores
        /// to the point of function entry.
        /// Uses the `un_node` field.
        restore_err_ret_index_unconditional,
        /// Specialized form of `Extended.restore_err_ret_index`.
        /// Restores the error return index to its state at the entry of
        /// the current function conditional on `operand` being a non-error.
        /// If `operand` is `none`, restores unconditionally.
        /// Uses the `un_node` field.
        restore_err_ret_index_fn_entry,

        /// The ZIR instruction tag is one of the `Extended` ones.
        /// Uses the `extended` union field.
        extended,

        /// Returns whether the instruction is one of the control flow "noreturn" types.
        /// Function calls do not count.
        pub fn isNoReturn(tag: Tag) bool {
            return switch (tag) {
                .param,
                .param_comptime,
                .param_anytype,
                .param_anytype_comptime,
                .add,
                .addwrap,
                .add_sat,
                .add_unsafe,
                .alloc,
                .alloc_mut,
                .alloc_comptime_mut,
                .alloc_inferred,
                .alloc_inferred_mut,
                .alloc_inferred_comptime,
                .alloc_inferred_comptime_mut,
                .make_ptr_const,
                .array_cat,
                .array_mul,
                .array_type,
                .array_type_sentinel,
                .vector_type,
                .elem_type,
                .indexable_ptr_elem_type,
                .vec_arr_elem_type,
                .indexable_ptr_len,
                .anyframe_type,
                .as_node,
                .as_shift_operand,
                .bit_and,
                .bitcast,
                .bit_or,
                .block,
                .block_comptime,
                .block_inline,
                .declaration,
                .suspend_block,
                .loop,
                .bool_br_and,
                .bool_br_or,
                .bool_not,
                .call,
                .field_call,
                .cmp_lt,
                .cmp_lte,
                .cmp_eq,
                .cmp_gte,
                .cmp_gt,
                .cmp_neq,
                .error_set_decl,
                .dbg_stmt,
                .dbg_var_ptr,
                .dbg_var_val,
                .decl_ref,
                .decl_val,
                .load,
                .div,
                .elem_ptr,
                .elem_val,
                .elem_ptr_node,
                .elem_val_node,
                .elem_val_imm,
                .ensure_result_used,
                .ensure_result_non_error,
                .ensure_err_union_payload_void,
                .@"export",
                .field_ptr,
                .field_val,
                .field_ptr_named,
                .field_val_named,
                .func,
                .func_inferred,
                .func_fancy,
                .has_decl,
                .int,
                .int_big,
                .float,
                .float128,
                .int_type,
                .is_non_null,
                .is_non_null_ptr,
                .is_non_err,
                .is_non_err_ptr,
                .ret_is_non_err,
                .mod_rem,
                .mul,
                .mulwrap,
                .mul_sat,
                .ref,
                .shl,
                .shl_sat,
                .shr,
                .store_node,
                .store_to_inferred_ptr,
                .str,
                .sub,
                .subwrap,
                .sub_sat,
                .negate,
                .negate_wrap,
                .typeof,
                .typeof_builtin,
                .xor,
                .optional_type,
                .optional_payload_safe,
                .optional_payload_unsafe,
                .optional_payload_safe_ptr,
                .optional_payload_unsafe_ptr,
                .err_union_payload_unsafe,
                .err_union_payload_unsafe_ptr,
                .err_union_code,
                .err_union_code_ptr,
                .ptr_type,
                .enum_literal,
                .decl_literal,
                .decl_literal_no_coerce,
                .merge_error_sets,
                .error_union_type,
                .bit_not,
                .error_value,
                .slice_start,
                .slice_end,
                .slice_sentinel,
                .slice_length,
                .slice_sentinel_ty,
                .import,
                .typeof_log2_int_type,
                .resolve_inferred_alloc,
                .set_eval_branch_quota,
                .switch_block,
                .switch_block_ref,
                .switch_block_err_union,
                .validate_deref,
                .validate_destructure,
                .union_init,
                .field_type_ref,
                .enum_from_int,
                .int_from_enum,
                .type_info,
                .size_of,
                .bit_size_of,
                .int_from_ptr,
                .align_of,
                .int_from_bool,
                .embed_file,
                .error_name,
                .set_runtime_safety,
                .sqrt,
                .sin,
                .cos,
                .tan,
                .exp,
                .exp2,
                .log,
                .log2,
                .log10,
                .abs,
                .floor,
                .ceil,
                .trunc,
                .round,
                .tag_name,
                .type_name,
                .frame_type,
                .int_from_float,
                .float_from_int,
                .ptr_from_int,
                .float_cast,
                .int_cast,
                .ptr_cast,
                .truncate,
                .has_field,
                .clz,
                .ctz,
                .pop_count,
                .byte_swap,
                .bit_reverse,
                .div_exact,
                .div_floor,
                .div_trunc,
                .mod,
                .rem,
                .shl_exact,
                .shr_exact,
                .bit_offset_of,
                .offset_of,
                .splat,
                .reduce,
                .shuffle,
                .atomic_load,
                .atomic_rmw,
                .atomic_store,
                .mul_add,
                .builtin_call,
                .max,
                .memcpy,
                .memset,
                .memmove,
                .min,
                .c_import,
                .@"resume",
                .ret_err_value_code,
                .extended,
                .ret_ptr,
                .ret_type,
                .@"try",
                .try_ptr,
                .@"defer",
                .defer_err_code,
                .save_err_ret_index,
                .for_len,
                .opt_eu_base_ptr_init,
                .coerce_ptr_elem_ty,
                .struct_init_empty,
                .struct_init_empty_result,
                .struct_init_empty_ref_result,
                .struct_init_anon,
                .struct_init,
                .struct_init_ref,
                .validate_struct_init_ty,
                .validate_struct_init_result_ty,
                .validate_ptr_struct_init,
                .struct_init_field_type,
                .struct_init_field_ptr,
                .array_init_anon,
                .array_init,
                .array_init_ref,
                .validate_array_init_ty,
                .validate_array_init_result_ty,
                .validate_array_init_ref_ty,
                .validate_ptr_array_init,
                .array_init_elem_type,
                .array_init_elem_ptr,
                .validate_ref_ty,
                .validate_const,
                .restore_err_ret_index_unconditional,
                .restore_err_ret_index_fn_entry,
                => false,

                .@"break",
                .break_inline,
                .condbr,
                .condbr_inline,
                .compile_error,
                .ret_node,
                .ret_load,
                .ret_implicit,
                .ret_err_value,
                .@"unreachable",
                .repeat,
                .repeat_inline,
                .panic,
                .trap,
                .check_comptime_control_flow,
                .switch_continue,
                => true,
            };
        }

        /// AstGen uses this to find out if `Ref.void_value` should be used in place
        /// of the result of a given instruction. This allows Sema to forego adding
        /// the instruction to the map after analysis.
        pub fn isAlwaysVoid(tag: Tag, data: Data) bool {
            return switch (tag) {
                .dbg_stmt,
                .dbg_var_ptr,
                .dbg_var_val,
                .ensure_result_used,
                .ensure_result_non_error,
                .ensure_err_union_payload_void,
                .set_eval_branch_quota,
                .atomic_store,
                .store_node,
                .store_to_inferred_ptr,
                .validate_deref,
                .validate_destructure,
                .@"export",
                .set_runtime_safety,
                .memcpy,
                .memset,
                .memmove,
                .check_comptime_control_flow,
                .@"defer",
                .defer_err_code,
                .save_err_ret_index,
                .restore_err_ret_index_unconditional,
                .restore_err_ret_index_fn_entry,
                .validate_struct_init_ty,
                .validate_struct_init_result_ty,
                .validate_ptr_struct_init,
                .validate_array_init_ty,
                .validate_array_init_result_ty,
                .validate_ptr_array_init,
                .validate_ref_ty,
                .validate_const,
                => true,

                .param,
                .param_comptime,
                .param_anytype,
                .param_anytype_comptime,
                .add,
                .addwrap,
                .add_sat,
                .add_unsafe,
                .alloc,
                .alloc_mut,
                .alloc_comptime_mut,
                .alloc_inferred,
                .alloc_inferred_mut,
                .alloc_inferred_comptime,
                .alloc_inferred_comptime_mut,
                .resolve_inferred_alloc,
                .make_ptr_const,
                .array_cat,
                .array_mul,
                .array_type,
                .array_type_sentinel,
                .vector_type,
                .elem_type,
                .indexable_ptr_elem_type,
                .vec_arr_elem_type,
                .indexable_ptr_len,
                .anyframe_type,
                .as_node,
                .as_shift_operand,
                .bit_and,
                .bitcast,
                .bit_or,
                .block,
                .block_comptime,
                .block_inline,
                .declaration,
                .suspend_block,
                .loop,
                .bool_br_and,
                .bool_br_or,
                .bool_not,
                .call,
                .field_call,
                .cmp_lt,
                .cmp_lte,
                .cmp_eq,
                .cmp_gte,
                .cmp_gt,
                .cmp_neq,
                .error_set_decl,
                .decl_ref,
                .decl_val,
                .load,
                .div,
                .elem_ptr,
                .elem_val,
                .elem_ptr_node,
                .elem_val_node,
                .elem_val_imm,
                .field_ptr,
                .field_val,
                .field_ptr_named,
                .field_val_named,
                .func,
                .func_inferred,
                .func_fancy,
                .has_decl,
                .int,
                .int_big,
                .float,
                .float128,
                .int_type,
                .is_non_null,
                .is_non_null_ptr,
                .is_non_err,
                .is_non_err_ptr,
                .ret_is_non_err,
                .mod_rem,
                .mul,
                .mulwrap,
                .mul_sat,
                .ref,
                .shl,
                .shl_sat,
                .shr,
                .str,
                .sub,
                .subwrap,
                .sub_sat,
                .negate,
                .negate_wrap,
                .typeof,
                .typeof_builtin,
                .xor,
                .optional_type,
                .optional_payload_safe,
                .optional_payload_unsafe,
                .optional_payload_safe_ptr,
                .optional_payload_unsafe_ptr,
                .err_union_payload_unsafe,
                .err_union_payload_unsafe_ptr,
                .err_union_code,
                .err_union_code_ptr,
                .ptr_type,
                .enum_literal,
                .decl_literal,
                .decl_literal_no_coerce,
                .merge_error_sets,
                .error_union_type,
                .bit_not,
                .error_value,
                .slice_start,
                .slice_end,
                .slice_sentinel,
                .slice_length,
                .slice_sentinel_ty,
                .import,
                .typeof_log2_int_type,
                .switch_block,
                .switch_block_ref,
                .switch_block_err_union,
                .union_init,
                .field_type_ref,
                .enum_from_int,
                .int_from_enum,
                .type_info,
                .size_of,
                .bit_size_of,
                .int_from_ptr,
                .align_of,
                .int_from_bool,
                .embed_file,
                .error_name,
                .sqrt,
                .sin,
                .cos,
                .tan,
                .exp,
                .exp2,
                .log,
                .log2,
                .log10,
                .abs,
                .floor,
                .ceil,
                .trunc,
                .round,
                .tag_name,
                .type_name,
                .frame_type,
                .int_from_float,
                .float_from_int,
                .ptr_from_int,
                .float_cast,
                .int_cast,
                .ptr_cast,
                .truncate,
                .has_field,
                .clz,
                .ctz,
                .pop_count,
                .byte_swap,
                .bit_reverse,
                .div_exact,
                .div_floor,
                .div_trunc,
                .mod,
                .rem,
                .shl_exact,
                .shr_exact,
                .bit_offset_of,
                .offset_of,
                .splat,
                .reduce,
                .shuffle,
                .atomic_load,
                .atomic_rmw,
                .mul_add,
                .builtin_call,
                .max,
                .min,
                .c_import,
                .@"resume",
                .ret_err_value_code,
                .@"break",
                .break_inline,
                .condbr,
                .condbr_inline,
                .switch_continue,
                .compile_error,
                .ret_node,
                .ret_load,
                .ret_implicit,
                .ret_err_value,
                .ret_ptr,
                .ret_type,
                .@"unreachable",
                .repeat,
                .repeat_inline,
                .panic,
                .trap,
                .for_len,
                .@"try",
                .try_ptr,
                .opt_eu_base_ptr_init,
                .coerce_ptr_elem_ty,
                .struct_init_empty,
                .struct_init_empty_result,
                .struct_init_empty_ref_result,
                .struct_init_anon,
                .struct_init,
                .struct_init_ref,
                .struct_init_field_type,
                .struct_init_field_ptr,
                .array_init_anon,
                .array_init,
                .array_init_ref,
                .validate_array_init_ref_ty,
                .array_init_elem_type,
                .array_init_elem_ptr,
                => false,

                .extended => switch (data.extended.opcode) {
                    .branch_hint,
                    .breakpoint,
                    .disable_instrumentation,
                    .disable_intrinsics,
                    => true,
                    else => false,
                },
            };
        }

        /// Used by debug safety-checking code.
        pub const data_tags = list: {
            @setEvalBranchQuota(2000);
            break :list std.enums.directEnumArray(Tag, Data.FieldEnum, 0, .{
                .add = .pl_node,
                .addwrap = .pl_node,
                .add_sat = .pl_node,
                .add_unsafe = .pl_node,
                .sub = .pl_node,
                .subwrap = .pl_node,
                .sub_sat = .pl_node,
                .mul = .pl_node,
                .mulwrap = .pl_node,
                .mul_sat = .pl_node,

                .param = .pl_tok,
                .param_comptime = .pl_tok,
                .param_anytype = .str_tok,
                .param_anytype_comptime = .str_tok,
                .array_cat = .pl_node,
                .array_mul = .pl_node,
                .array_type = .pl_node,
                .array_type_sentinel = .pl_node,
                .vector_type = .pl_node,
                .elem_type = .un_node,
                .indexable_ptr_elem_type = .un_node,
                .vec_arr_elem_type = .un_node,
                .indexable_ptr_len = .un_node,
                .anyframe_type = .un_node,
                .as_node = .pl_node,
                .as_shift_operand = .pl_node,
                .bit_and = .pl_node,
                .bitcast = .pl_node,
                .bit_not = .un_node,
                .bit_or = .pl_node,
                .block = .pl_node,
                .block_comptime = .pl_node,
                .block_inline = .pl_node,
                .declaration = .declaration,
                .suspend_block = .pl_node,
                .bool_not = .un_node,
                .bool_br_and = .pl_node,
                .bool_br_or = .pl_node,
                .@"break" = .@"break",
                .break_inline = .@"break",
                .switch_continue = .@"break",
                .check_comptime_control_flow = .un_node,
                .for_len = .pl_node,
                .call = .pl_node,
                .field_call = .pl_node,
                .cmp_lt = .pl_node,
                .cmp_lte = .pl_node,
                .cmp_eq = .pl_node,
                .cmp_gte = .pl_node,
                .cmp_gt = .pl_node,
                .cmp_neq = .pl_node,
                .condbr = .pl_node,
                .condbr_inline = .pl_node,
                .@"try" = .pl_node,
                .try_ptr = .pl_node,
                .error_set_decl = .pl_node,
                .dbg_stmt = .dbg_stmt,
                .dbg_var_ptr = .str_op,
                .dbg_var_val = .str_op,
                .decl_ref = .str_tok,
                .decl_val = .str_tok,
                .load = .un_node,
                .div = .pl_node,
                .elem_ptr = .pl_node,
                .elem_ptr_node = .pl_node,
                .elem_val = .pl_node,
                .elem_val_node = .pl_node,
                .elem_val_imm = .elem_val_imm,
                .ensure_result_used = .un_node,
                .ensure_result_non_error = .un_node,
                .ensure_err_union_payload_void = .un_node,
                .error_union_type = .pl_node,
                .error_value = .str_tok,
                .@"export" = .pl_node,
                .field_ptr = .pl_node,
                .field_val = .pl_node,
                .field_ptr_named = .pl_node,
                .field_val_named = .pl_node,
                .func = .pl_node,
                .func_inferred = .pl_node,
                .func_fancy = .pl_node,
                .import = .pl_tok,
                .int = .int,
                .int_big = .str,
                .float = .float,
                .float128 = .pl_node,
                .int_type = .int_type,
                .is_non_null = .un_node,
                .is_non_null_ptr = .un_node,
                .is_non_err = .un_node,
                .is_non_err_ptr = .un_node,
                .ret_is_non_err = .un_node,
                .loop = .pl_node,
                .repeat = .node,
                .repeat_inline = .node,
                .merge_error_sets = .pl_node,
                .mod_rem = .pl_node,
                .ref = .un_tok,
                .ret_node = .un_node,
                .ret_load = .un_node,
                .ret_implicit = .un_tok,
                .ret_err_value = .str_tok,
                .ret_err_value_code = .str_tok,
                .ret_ptr = .node,
                .ret_type = .node,
                .ptr_type = .ptr_type,
                .slice_start = .pl_node,
                .slice_end = .pl_node,
                .slice_sentinel = .pl_node,
                .slice_length = .pl_node,
                .slice_sentinel_ty = .un_node,
                .store_node = .pl_node,
                .store_to_inferred_ptr = .pl_node,
                .str = .str,
                .negate = .un_node,
                .negate_wrap = .un_node,
                .typeof = .un_node,
                .typeof_log2_int_type = .un_node,
                .@"unreachable" = .@"unreachable",
                .xor = .pl_node,
                .optional_type = .un_node,
                .optional_payload_safe = .un_node,
                .optional_payload_unsafe = .un_node,
                .optional_payload_safe_ptr = .un_node,
                .optional_payload_unsafe_ptr = .un_node,
                .err_union_payload_unsafe = .un_node,
                .err_union_payload_unsafe_ptr = .un_node,
                .err_union_code = .un_node,
                .err_union_code_ptr = .un_node,
                .enum_literal = .str_tok,
                .decl_literal = .pl_node,
                .decl_literal_no_coerce = .pl_node,
                .switch_block = .pl_node,
                .switch_block_ref = .pl_node,
                .switch_block_err_union = .pl_node,
                .validate_deref = .un_node,
                .validate_destructure = .pl_node,
                .field_type_ref = .pl_node,
                .union_init = .pl_node,
                .type_info = .un_node,
                .size_of = .un_node,
                .bit_size_of = .un_node,
                .opt_eu_base_ptr_init = .un_node,
                .coerce_ptr_elem_ty = .pl_node,
                .validate_ref_ty = .un_tok,
                .validate_const = .un_node,

                .int_from_ptr = .un_node,
                .compile_error = .un_node,
                .set_eval_branch_quota = .un_node,
                .int_from_enum = .un_node,
                .align_of = .un_node,
                .int_from_bool = .un_node,
                .embed_file = .un_node,
                .error_name = .un_node,
                .panic = .un_node,
                .trap = .node,
                .set_runtime_safety = .un_node,
                .sqrt = .un_node,
                .sin = .un_node,
                .cos = .un_node,
                .tan = .un_node,
                .exp = .un_node,
                .exp2 = .un_node,
                .log = .un_node,
                .log2 = .un_node,
                .log10 = .un_node,
                .abs = .un_node,
                .floor = .un_node,
                .ceil = .un_node,
                .trunc = .un_node,
                .round = .un_node,
                .tag_name = .un_node,
                .type_name = .un_node,
                .frame_type = .un_node,

                .int_from_float = .pl_node,
                .float_from_int = .pl_node,
                .ptr_from_int = .pl_node,
                .enum_from_int = .pl_node,
                .float_cast = .pl_node,
                .int_cast = .pl_node,
                .ptr_cast = .pl_node,
                .truncate = .pl_node,
                .typeof_builtin = .pl_node,

                .has_decl = .pl_node,
                .has_field = .pl_node,

                .clz = .un_node,
                .ctz = .un_node,
                .pop_count = .un_node,
                .byte_swap = .un_node,
                .bit_reverse = .un_node,

                .div_exact = .pl_node,
                .div_floor = .pl_node,
                .div_trunc = .pl_node,
                .mod = .pl_node,
                .rem = .pl_node,

                .shl = .pl_node,
                .shl_exact = .pl_node,
                .shl_sat = .pl_node,
                .shr = .pl_node,
                .shr_exact = .pl_node,

                .bit_offset_of = .pl_node,
                .offset_of = .pl_node,
                .splat = .pl_node,
                .reduce = .pl_node,
                .shuffle = .pl_node,
                .atomic_load = .pl_node,
                .atomic_rmw = .pl_node,
                .atomic_store = .pl_node,
                .mul_add = .pl_node,
                .builtin_call = .pl_node,
                .max = .pl_node,
                .memcpy = .pl_node,
                .memset = .pl_node,
                .memmove = .pl_node,
                .min = .pl_node,
                .c_import = .pl_node,

                .alloc = .un_node,
                .alloc_mut = .un_node,
                .alloc_comptime_mut = .un_node,
                .alloc_inferred = .node,
                .alloc_inferred_mut = .node,
                .alloc_inferred_comptime = .node,
                .alloc_inferred_comptime_mut = .node,
                .resolve_inferred_alloc = .un_node,
                .make_ptr_const = .un_node,

                .@"resume" = .un_node,

                .@"defer" = .@"defer",
                .defer_err_code = .defer_err_code,

                .save_err_ret_index = .save_err_ret_index,
                .restore_err_ret_index_unconditional = .un_node,
                .restore_err_ret_index_fn_entry = .un_node,

                .struct_init_empty = .un_node,
                .struct_init_empty_result = .un_node,
                .struct_init_empty_ref_result = .un_node,
                .struct_init_anon = .pl_node,
                .struct_init = .pl_node,
                .struct_init_ref = .pl_node,
                .validate_struct_init_ty = .un_node,
                .validate_struct_init_result_ty = .un_node,
                .validate_ptr_struct_init = .pl_node,
                .struct_init_field_type = .pl_node,
                .struct_init_field_ptr = .pl_node,
                .array_init_anon = .pl_node,
                .array_init = .pl_node,
                .array_init_ref = .pl_node,
                .validate_array_init_ty = .pl_node,
                .validate_array_init_result_ty = .pl_node,
                .validate_array_init_ref_ty = .pl_node,
                .validate_ptr_array_init = .pl_node,
                .array_init_elem_type = .bin,
                .array_init_elem_ptr = .pl_node,

                .extended = .extended,
            });
        };

        // Uncomment to view how many tag slots are available.
        //comptime {
        //    @compileLog("ZIR tags left: ", 256 - @typeInfo(Tag).@"enum".fields.len);
        //}
    };

    /// Rarer instructions are here; ones that do not fit in the 8-bit `Tag` enum.
    /// `noreturn` instructions may not go here; they must be part of the main `Tag` enum.
    pub const Extended = enum(u16) {
        /// A struct type definition. Contains references to ZIR instructions for
        /// the field types, defaults, and alignments.
        /// `operand` is payload index to `StructDecl`.
        /// `small` is `StructDecl.Small`.
        struct_decl,
        /// An enum type definition. Contains references to ZIR instructions for
        /// the field value expressions and optional type tag expression.
        /// `operand` is payload index to `EnumDecl`.
        /// `small` is `EnumDecl.Small`.
        enum_decl,
        /// A union type definition. Contains references to ZIR instructions for
        /// the field types and optional type tag expression.
        /// `operand` is payload index to `UnionDecl`.
        /// `small` is `UnionDecl.Small`.
        union_decl,
        /// An opaque type definition. Contains references to decls and captures.
        /// `operand` is payload index to `OpaqueDecl`.
        /// `small` is `OpaqueDecl.Small`.
        opaque_decl,
        /// A tuple type. Note that tuples are not namespace/container types.
        /// `operand` is payload index to `TupleDecl`.
        /// `small` is `fields_len: u16`.
        tuple_decl,
        /// Implements the `@This` builtin.
        /// `operand` is `src_node: Ast.Node.Offset`.
        this,
        /// Implements the `@returnAddress` builtin.
        /// `operand` is `src_node: Ast.Node.Offset`.
        ret_addr,
        /// Implements the `@src` builtin.
        /// `operand` is payload index to `LineColumn`.
        builtin_src,
        /// Implements the `@errorReturnTrace` builtin.
        /// `operand` is `src_node: Ast.Node.Offset`.
        error_return_trace,
        /// Implements the `@frame` builtin.
        /// `operand` is `src_node: Ast.Node.Offset`.
        frame,
        /// Implements the `@frameAddress` builtin.
        /// `operand` is `src_node: Ast.Node.Offset`.
        frame_address,
        /// Same as `alloc` from `Tag` but may contain an alignment instruction.
        /// `operand` is payload index to `AllocExtended`.
        /// `small`:
        ///  * 0b000X - has type
        ///  * 0b00X0 - has alignment
        ///  * 0b0X00 - 1=const, 0=var
        ///  * 0bX000 - is comptime
        alloc,
        /// The `@extern` builtin.
        /// `operand` is payload index to `BinNode`.
        builtin_extern,
        /// Inline assembly.
        /// `operand` is payload index to `Asm`.
        @"asm",
        /// Same as `asm` except the assembly template is not a string literal but a comptime
        /// expression.
        /// The `asm_source` field of the Asm is not a null-terminated string
        /// but instead a Ref.
        asm_expr,
        /// Log compile time variables and emit an error message.
        /// `operand` is payload index to `NodeMultiOp`.
        /// `small` is `operands_len`.
        /// The AST node is the compile log builtin call.
        compile_log,
        /// The builtin `@TypeOf` which returns the type after Peer Type Resolution
        /// of one or more params.
        /// `operand` is payload index to `TypeOfPeer`.
        /// `small` is `operands_len`.
        /// The AST node is the builtin call.
        typeof_peer,
        /// Implements the `@min` builtin for more than 2 args.
        /// `operand` is payload index to `NodeMultiOp`.
        /// `small` is `operands_len`.
        /// The AST node is the builtin call.
        min_multi,
        /// Implements the `@max` builtin for more than 2 args.
        /// `operand` is payload index to `NodeMultiOp`.
        /// `small` is `operands_len`.
        /// The AST node is the builtin call.
        max_multi,
        /// Implements the `@addWithOverflow` builtin.
        /// `operand` is payload index to `BinNode`.
        /// `small` is unused.
        add_with_overflow,
        /// Implements the `@subWithOverflow` builtin.
        /// `operand` is payload index to `BinNode`.
        /// `small` is unused.
        sub_with_overflow,
        /// Implements the `@mulWithOverflow` builtin.
        /// `operand` is payload index to `BinNode`.
        /// `small` is unused.
        mul_with_overflow,
        /// Implements the `@shlWithOverflow` builtin.
        /// `operand` is payload index to `BinNode`.
        /// `small` is unused.
        shl_with_overflow,
        /// `operand` is payload index to `UnNode`.
        c_undef,
        /// `operand` is payload index to `UnNode`.
        c_include,
        /// `operand` is payload index to `BinNode`.
        c_define,
        /// `operand` is payload index to `UnNode`.
        wasm_memory_size,
        /// `operand` is payload index to `BinNode`.
        wasm_memory_grow,
        /// The `@prefetch` builtin.
        /// `operand` is payload index to `BinNode`.
        prefetch,
        /// Implement builtin `@setFloatMode`.
        /// `operand` is payload index to `UnNode`.
        set_float_mode,
        /// Implements the `@errorCast` builtin.
        /// `operand` is payload index to `BinNode`. `lhs` is dest type, `rhs` is operand.
        error_cast,
        /// Implements `@breakpoint`.
        /// `operand` is `src_node: Ast.Node.Offset`.
        breakpoint,
        /// Implement builtin `@disableInstrumentation`. `operand` is `src_node: Ast.Node.Offset`.
        disable_instrumentation,
        /// Implement builtin `@disableIntrinsics`. `operand` is `src_node: i32`.
        disable_intrinsics,
        /// Implements the `@select` builtin.
        /// `operand` is payload index to `Select`.
        select,
        /// Implement builtin `@errToInt`.
        /// `operand` is payload index to `UnNode`.
        int_from_error,
        /// Implement builtin `@errorFromInt`.
        /// `operand` is payload index to `UnNode`.
        error_from_int,
        /// Implement builtin `@Type`.
        /// `operand` is payload index to `Reify`.
        /// `small` contains `NameStrategy`.
        reify,
        /// Implements the `@cmpxchgStrong` and `@cmpxchgWeak` builtins.
        /// `small` 0=>weak 1=>strong
        /// `operand` is payload index to `Cmpxchg`.
        cmpxchg,
        /// Implement builtin `@cVaArg`.
        /// `operand` is payload index to `BinNode`.
        c_va_arg,
        /// Implement builtin `@cVaCopy`.
        /// `operand` is payload index to `UnNode`.
        c_va_copy,
        /// Implement builtin `@cVaEnd`.
        /// `operand` is payload index to `UnNode`.
        c_va_end,
        /// Implement builtin `@cVaStart`.
        /// `operand` is `src_node: Ast.Node.Offset`.
        c_va_start,
        /// Implements the following builtins:
        /// `@ptrCast`, `@alignCast`, `@addrSpaceCast`, `@constCast`, `@volatileCast`.
        /// Represents an arbitrary nesting of the above builtins. Such a nesting is treated as a
        /// single operation which can modify multiple components of a pointer type.
        /// `operand` is payload index to `BinNode`.
        /// `small` contains `FullPtrCastFlags`.
        /// AST node is the root of the nested casts.
        /// `lhs` is dest type, `rhs` is operand.
        ptr_cast_full,
        /// `operand` is payload index to `UnNode`.
        /// `small` contains `FullPtrCastFlags`.
        /// Guaranteed to only have flags where no explicit destination type is
        /// required (const_cast and volatile_cast).
        /// AST node is the root of the nested casts.
        ptr_cast_no_dest,
        /// Implements the `@workItemId` builtin.
        /// `operand` is payload index to `UnNode`.
        work_item_id,
        /// Implements the `@workGroupSize` builtin.
        /// `operand` is payload index to `UnNode`.
        work_group_size,
        /// Implements the `@workGroupId` builtin.
        /// `operand` is payload index to `UnNode`.
        work_group_id,
        /// Implements the `@inComptime` builtin.
        /// `operand` is `src_node: Ast.Node.Offset`.
        in_comptime,
        /// Restores the error return index to its last saved state in a given
        /// block. If the block is `.none`, restores to the state from the point
        /// of function entry. If the operand is not `.none`, the restore is
        /// conditional on the operand value not being an error.
        /// `operand` is payload index to `RestoreErrRetIndex`.
        /// `small` is undefined.
        restore_err_ret_index,
        /// Retrieves a value from the current type declaration scope's closure.
        /// `operand` is `src_node: Ast.Node.Offset`.
        /// `small` is closure index.
        closure_get,
        /// Used as a placeholder instruction which is just a dummy index for Sema to replace
        /// with a specific value. For instance, this is used for the capture of an `errdefer`.
        /// This should never appear in a body.
        value_placeholder,
        /// Implements the `@fieldParentPtr` builtin.
        /// `operand` is payload index to `FieldParentPtr`.
        /// `small` contains `FullPtrCastFlags`.
        /// Guaranteed to not have the `ptr_cast` flag.
        /// Uses the `pl_node` union field with payload `FieldParentPtr`.
        field_parent_ptr,
        /// Get a type or value from `std.builtin`.
        /// `operand` is `src_node: Ast.Node.Offset`.
        /// `small` is an `Inst.BuiltinValue`.
        builtin_value,
        /// Provide a `@branchHint` for the current block.
        /// `operand` is payload index to `UnNode`.
        /// `small` is unused.
        branch_hint,
        /// Compute the result type for in-place arithmetic, e.g. `+=`.
        /// `operand` is `Zir.Inst.Ref` of the loaded LHS (*not* its type).
        /// `small` is an `Inst.InplaceOp`.
        inplace_arith_result_ty,
        /// Marks a statement that can be stepped to but produces no code.
        /// `operand` and `small` are ignored.
        dbg_empty_stmt,
        /// At this point, AstGen encountered a fatal error which terminated ZIR lowering for this body.
        /// A file-level error has been reported. Sema should terminate semantic analysis.
        /// `operand` and `small` are ignored.
        /// This instruction is always `noreturn`, however, it is not considered as such by ZIR-level queries. This allows AstGen to assume that
        /// any code may have gone here, avoiding false-positive "unreachable code" errors.
        astgen_error,

        pub const InstData = struct {
            opcode: Extended,
            small: u16,
            operand: u32,
        };
    };

    /// The position of a ZIR instruction within the `Zir` instructions array.
    pub const Index = enum(u32) {
        /// ZIR is structured so that the outermost "main" struct of any file
        /// is always at index 0.
        main_struct_inst = 0,
        ref_start_index = static_len,
        _,

        pub const static_len = 124;

        pub fn toRef(i: Index) Inst.Ref {
            return @enumFromInt(@intFromEnum(Index.ref_start_index) + @intFromEnum(i));
        }

        pub fn toOptional(i: Index) OptionalIndex {
            return @enumFromInt(@intFromEnum(i));
        }
    };

    pub const OptionalIndex = enum(u32) {
        /// ZIR is structured so that the outermost "main" struct of any file
        /// is always at index 0.
        main_struct_inst = 0,
        ref_start_index = Index.static_len,
        none = std.math.maxInt(u32),
        _,

        pub fn unwrap(oi: OptionalIndex) ?Index {
            return if (oi == .none) null else @enumFromInt(@intFromEnum(oi));
        }
    };

    /// A reference to ZIR instruction, or to an InternPool index, or neither.
    ///
    /// If the integer tag value is < InternPool.static_len, then it
    /// corresponds to an InternPool index. Otherwise, this refers to a ZIR
    /// instruction.
    ///
    /// The tag type is specified so that it is safe to bitcast between `[]u32`
    /// and `[]Ref`.
    pub const Ref = enum(u32) {
        u0_type,
        i0_type,
        u1_type,
        u8_type,
        i8_type,
        u16_type,
        i16_type,
        u29_type,
        u32_type,
        i32_type,
        u64_type,
        i64_type,
        u80_type,
        u128_type,
        i128_type,
        u256_type,
        usize_type,
        isize_type,
        c_char_type,
        c_short_type,
        c_ushort_type,
        c_int_type,
        c_uint_type,
        c_long_type,
        c_ulong_type,
        c_longlong_type,
        c_ulonglong_type,
        c_longdouble_type,
        f16_type,
        f32_type,
        f64_type,
        f80_type,
        f128_type,
        anyopaque_type,
        bool_type,
        void_type,
        type_type,
        anyerror_type,
        comptime_int_type,
        comptime_float_type,
        noreturn_type,
        anyframe_type,
        null_type,
        undefined_type,
        enum_literal_type,
        ptr_usize_type,
        ptr_const_comptime_int_type,
        manyptr_u8_type,
        manyptr_const_u8_type,
        manyptr_const_u8_sentinel_0_type,
        slice_const_u8_type,
        slice_const_u8_sentinel_0_type,
        vector_8_i8_type,
        vector_16_i8_type,
        vector_32_i8_type,
        vector_64_i8_type,
        vector_1_u8_type,
        vector_2_u8_type,
        vector_4_u8_type,
        vector_8_u8_type,
        vector_16_u8_type,
        vector_32_u8_type,
        vector_64_u8_type,
        vector_2_i16_type,
        vector_4_i16_type,
        vector_8_i16_type,
        vector_16_i16_type,
        vector_32_i16_type,
        vector_4_u16_type,
        vector_8_u16_type,
        vector_16_u16_type,
        vector_32_u16_type,
        vector_2_i32_type,
        vector_4_i32_type,
        vector_8_i32_type,
        vector_16_i32_type,
        vector_4_u32_type,
        vector_8_u32_type,
        vector_16_u32_type,
        vector_2_i64_type,
        vector_4_i64_type,
        vector_8_i64_type,
        vector_2_u64_type,
        vector_4_u64_type,
        vector_8_u64_type,
        vector_1_u128_type,
        vector_2_u128_type,
        vector_1_u256_type,
        vector_4_f16_type,
        vector_8_f16_type,
        vector_16_f16_type,
        vector_32_f16_type,
        vector_2_f32_type,
        vector_4_f32_type,
        vector_8_f32_type,
        vector_16_f32_type,
        vector_2_f64_type,
        vector_4_f64_type,
        vector_8_f64_type,
        optional_noreturn_type,
        anyerror_void_error_union_type,
        adhoc_inferred_error_set_type,
        generic_poison_type,
        empty_tuple_type,
        undef,
        undef_bool,
        undef_usize,
        undef_u1,
        zero,
        zero_usize,
        zero_u1,
        zero_u8,
        one,
        one_usize,
        one_u1,
        one_u8,
        four_u8,
        negative_one,
        void_value,
        unreachable_value,
        null_value,
        bool_true,
        bool_false,
        empty_tuple,

        /// This Ref does not correspond to any ZIR instruction or constant
        /// value and may instead be used as a sentinel to indicate null.
        none = std.math.maxInt(u32),

        _,

        pub fn toIndex(inst: Ref) ?Index {
            assert(inst != .none);
            const ref_int = @intFromEnum(inst);
            if (ref_int >= @intFromEnum(Index.ref_start_index)) {
                return @enumFromInt(ref_int - @intFromEnum(Index.ref_start_index));
            } else {
                return null;
            }
        }

        pub fn toIndexAllowNone(inst: Ref) ?Index {
            if (inst == .none) return null;
            return toIndex(inst);
        }
    };

    /// All instructions have an 8-byte payload, which is contained within
    /// this union. `Tag` determines which union field is active, as well as
    /// how to interpret the data within.
    pub const Data = union {
        /// Used for `Tag.extended`. The extended opcode determines the meaning
        /// of the `small` and `operand` fields.
        extended: Extended.InstData,
        /// Used for unary operators, with an AST node source location.
        un_node: struct {
            /// Offset from Decl AST node index.
            src_node: Ast.Node.Offset,
            /// The meaning of this operand depends on the corresponding `Tag`.
            operand: Ref,
        },
        /// Used for unary operators, with a token source location.
        un_tok: struct {
            /// Offset from Decl AST token index.
            src_tok: Ast.TokenOffset,
            /// The meaning of this operand depends on the corresponding `Tag`.
            operand: Ref,
        },
        pl_node: struct {
            /// Offset from Decl AST node index.
            /// `Tag` determines which kind of AST node this points to.
            src_node: Ast.Node.Offset,
            /// index into extra.
            /// `Tag` determines what lives there.
            payload_index: u32,
        },
        pl_tok: struct {
            /// Offset from Decl AST token index.
            src_tok: Ast.TokenOffset,
            /// index into extra.
            /// `Tag` determines what lives there.
            payload_index: u32,
        },
        bin: Bin,
        /// For strings which may contain null bytes.
        str: struct {
            /// Offset into `string_bytes`.
            start: NullTerminatedString,
            /// Number of bytes in the string.
            len: u32,

            pub fn get(self: @This(), code: Zir) []const u8 {
                return code.string_bytes[@intFromEnum(self.start)..][0..self.len];
            }
        },
        str_tok: struct {
            /// Offset into `string_bytes`. Null-terminated.
            start: NullTerminatedString,
            /// Offset from Decl AST token index.
            src_tok: Ast.TokenOffset,

            pub fn get(self: @This(), code: Zir) [:0]const u8 {
                return code.nullTerminatedString(self.start);
            }
        },
        /// Offset from Decl AST token index.
        tok: Ast.TokenOffset,
        /// Offset from Decl AST node index.
        node: Ast.Node.Offset,
        int: u64,
        float: f64,
        ptr_type: struct {
            flags: packed struct {
                is_allowzero: bool,
                is_mutable: bool,
                is_volatile: bool,
                has_sentinel: bool,
                has_align: bool,
                has_addrspace: bool,
                has_bit_range: bool,
                _: u1 = undefined,
            },
            size: std.builtin.Type.Pointer.Size,
            /// Index into extra. See `PtrType`.
            payload_index: u32,
        },
        int_type: struct {
            /// Offset from Decl AST node index.
            /// `Tag` determines which kind of AST node this points to.
            src_node: Ast.Node.Offset,
            signedness: std.builtin.Signedness,
            bit_count: u16,
        },
        @"unreachable": struct {
            /// Offset from Decl AST node index.
            /// `Tag` determines which kind of AST node this points to.
            src_node: Ast.Node.Offset,
        },
        @"break": struct {
            operand: Ref,
            /// Index of a `Break` payload.
            payload_index: u32,
        },
        dbg_stmt: LineColumn,
        /// Used for unary operators which reference an inst,
        /// with an AST node source location.
        inst_node: struct {
            /// Offset from Decl AST node index.
            src_node: Ast.Node.Offset,
            /// The meaning of this operand depends on the corresponding `Tag`.
            inst: Index,
        },
        str_op: struct {
            /// Offset into `string_bytes`. Null-terminated.
            str: NullTerminatedString,
            operand: Ref,

            pub fn getStr(self: @This(), zir: Zir) [:0]const u8 {
                return zir.nullTerminatedString(self.str);
            }
        },
        @"defer": struct {
            index: u32,
            len: u32,
        },
        defer_err_code: struct {
            err_code: Ref,
            payload_index: u32,
        },
        save_err_ret_index: struct {
            operand: Ref, // If error type (or .none), save new trace index
        },
        elem_val_imm: struct {
            /// The indexable value being accessed.
            operand: Ref,
            /// The index being accessed.
            idx: u32,
        },
        declaration: struct {
            /// This node provides a new absolute baseline node for all instructions within this struct.
            src_node: Ast.Node.Index,
            /// index into extra to a `Declaration` payload.
            payload_index: u32,
        },

        // Make sure we don't accidentally add a field to make this union
        // bigger than expected. Note that in Debug builds, Zig is allowed
        // to insert a secret field for safety checks.
        comptime {
            if (builtin.mode != .Debug and builtin.mode != .ReleaseSafe) {
                assert(@sizeOf(Data) == 8);
            }
        }

        /// TODO this has to be kept in sync with `Data` which we want to be an untagged
        /// union. There is some kind of language awkwardness here and it has to do with
        /// deserializing an untagged union (in this case `Data`) from a file, and trying
        /// to preserve the hidden safety field.
        pub const FieldEnum = enum {
            extended,
            un_node,
            un_tok,
            pl_node,
            pl_tok,
            bin,
            str,
            str_tok,
            tok,
            node,
            int,
            float,
            ptr_type,
            int_type,
            @"unreachable",
            @"break",
            dbg_stmt,
            inst_node,
            str_op,
            @"defer",
            defer_err_code,
            save_err_ret_index,
            elem_val_imm,
            declaration,
        };
    };

    pub const Break = struct {
        operand_src_node: Ast.Node.OptionalOffset,
        block_inst: Index,
    };

    /// Trailing:
    /// 0. Output for every outputs_len
    /// 1. Input for every inputs_len
    pub const Asm = struct {
        src_node: Ast.Node.Offset,
        // null-terminated string index
        asm_source: NullTerminatedString,
        /// 1 bit for each outputs_len: whether it uses `-> T` or not.
        ///   0b0 - operand is a pointer to where to store the output.
        ///   0b1 - operand is a type; asm expression has the output as the result.
        /// 0b0X is the first output, 0bX0 is the second, etc.
        output_type_bits: u32,
        clobbers: Ref,

        pub const Small = packed struct(u16) {
            is_volatile: bool,
            outputs_len: u7,
            inputs_len: u8,
        };

        pub const Output = struct {
            /// index into string_bytes (null terminated)
            name: NullTerminatedString,
            /// index into string_bytes (null terminated)
            constraint: NullTerminatedString,
            /// How to interpret this is determined by `output_type_bits`.
            operand: Ref,
        };

        pub const Input = struct {
            /// index into string_bytes (null terminated)
            name: NullTerminatedString,
            /// index into string_bytes (null terminated)
            constraint: NullTerminatedString,
            operand: Ref,
        };
    };

    /// Trailing:
    /// if (ret_ty.body_len == 1) {
    ///   0. return_type: Ref
    /// }
    /// if (ret_ty.body_len > 1) {
    ///   1. return_type: Index // for each ret_ty.body_len
    /// }
    /// 2. body: Index // for each body_len
    /// 3. src_locs: SrcLocs // if body_len != 0
    /// 4. proto_hash: std.zig.SrcHash // if body_len != 0; hash of function prototype
    pub const Func = struct {
        ret_ty: RetTy,
        /// Points to the block that contains the param instructions for this function.
        /// If this is a `declaration`, it refers to the declaration's value body.
        param_block: Index,
        body_len: u32,

        pub const RetTy = packed struct(u32) {
            /// 0 means `void`.
            /// 1 means the type is a simple `Ref`.
            /// Otherwise, the length of a trailing body.
            body_len: u31,
            /// Whether the return type is generic, i.e. refers to one or more previous parameters.
            is_generic: bool,
        };

        pub const SrcLocs = struct {
            /// Line index in the source file relative to the parent decl.
            lbrace_line: u32,
            /// Line index in the source file relative to the parent decl.
            rbrace_line: u32,
            /// lbrace_column is least significant bits u16
            /// rbrace_column is most significant bits u16
            columns: u32,
        };
    };

    /// Trailing:
    /// if (has_cc_ref and !has_cc_body) {
    ///   0. cc: Ref,
    /// }
    /// if (has_cc_body) {
    ///   1. cc_body_len: u32
    ///   2. cc_body: u32 // for each cc_body_len
    /// }
    /// if (has_ret_ty_ref and !has_ret_ty_body) {
    ///   3. ret_ty: Ref,
    /// }
    /// if (has_ret_ty_body) {
    ///   4. ret_ty_body_len: u32
    ///   5. ret_ty_body: u32 // for each ret_ty_body_len
    /// }
    /// 6. noalias_bits: u32 // if has_any_noalias
    ///    - each bit starting with LSB corresponds to parameter indexes
    /// 7. body: Index // for each body_len
    /// 8. src_locs: Func.SrcLocs // if body_len != 0
    /// 9. proto_hash: std.zig.SrcHash // if body_len != 0; hash of function prototype
    pub const FuncFancy = struct {
        /// Points to the block that contains the param instructions for this function.
        /// If this is a `declaration`, it refers to the declaration's value body.
        param_block: Index,
        body_len: u32,
        bits: Bits,

        /// If both has_cc_ref and has_cc_body are false, it means auto calling convention.
        /// If both has_ret_ty_ref and has_ret_ty_body are false, it means void return type.
        pub const Bits = packed struct(u32) {
            is_var_args: bool,
            is_inferred_error: bool,
            is_noinline: bool,
            has_cc_ref: bool,
            has_cc_body: bool,
            has_ret_ty_ref: bool,
            has_ret_ty_body: bool,
            has_any_noalias: bool,
            ret_ty_is_generic: bool,
            _: u23 = undefined,
        };
    };

    /// This data is stored inside extra, with trailing operands according to `operands_len`.
    /// Each operand is a `Ref`.
    pub const MultiOp = struct {
        operands_len: u32,
    };

    /// Trailing: operand: Ref, // for each `operands_len` (stored in `small`).
    pub const NodeMultiOp = struct {
        src_node: Ast.Node.Offset,
    };

    /// This data is stored inside extra, with trailing operands according to `body_len`.
    /// Each operand is an `Index`.
    pub const Block = struct {
        body_len: u32,
    };

    /// Trailing:
    /// * inst: Index // for each `body_len`
    pub const BlockComptime = struct {
        reason: std.zig.SimpleComptimeReason,
        body_len: u32,
    };

    /// Trailing:
    /// * inst: Index // for each `body_len`
    pub const BoolBr = struct {
        lhs: Ref,
        body_len: u32,
    };

    /// Trailing:
    /// 0. name: NullTerminatedString      // if `flags.id.hasName()`
    /// 1. lib_name: NullTerminatedString  // if `flags.id.hasLibName()`
    /// 2. type_body_len: u32              // if `flags.id.hasTypeBody()`
    /// 3. align_body_len: u32             // if `flags.id.hasSpecialBodies()`
    /// 4. linksection_body_len: u32       // if `flags.id.hasSpecialBodies()`
    /// 5. addrspace_body_len: u32         // if `flags.id.hasSpecialBodies()`
    /// 6. value_body_len: u32             // if `flags.id.hasValueBody()`
    /// 7. type_body_inst: Zir.Inst.Index
    ///    - for each `type_body_len`
    ///    - body to be exited via `break_inline` to this `declaration` instruction
    /// 8. align_body_inst: Zir.Inst.Index
    ///    - for each `align_body_len`
    ///    - body to be exited via `break_inline` to this `declaration` instruction
    /// 9. linksection_body_inst: Zir.Inst.Index
    ///    - for each `linksection_body_len`
    ///    - body to be exited via `break_inline` to this `declaration` instruction
    /// 10. addrspace_body_inst: Zir.Inst.Index
    ///    - for each `addrspace_body_len`
    ///    - body to be exited via `break_inline` to this `declaration` instruction
    /// 11. value_body_inst: Zir.Inst.Index
    ///    - for each `value_body_len`
    ///    - body to be exited via `break_inline` to this `declaration` instruction
    ///    - within this body, the `declaration` instruction refers to the resolved type from the type body
    pub const Declaration = struct {
        // These fields should be concatenated and reinterpreted as a `std.zig.SrcHash`.
        src_hash_0: u32,
        src_hash_1: u32,
        src_hash_2: u32,
        src_hash_3: u32,
        // These fields should be concatenated and reinterpreted as a `Flags`.
        flags_0: u32,
        flags_1: u32,

        pub const Unwrapped = struct {
            pub const Kind = enum {
                unnamed_test,
                @"test",
                decltest,
                @"comptime",
                @"const",
                @"var",
            };

            pub const Linkage = enum {
                normal,
                @"extern",
                @"export",
            };

            src_node: Ast.Node.Index,

            src_line: u32,
            src_column: u32,

            kind: Kind,
            /// Always `.empty` for `kind` of `unnamed_test`, `.@"comptime"`
            name: NullTerminatedString,
            /// Always `false` for `kind` of `unnamed_test`, `.@"test"`, `.decltest`, `.@"comptime"`.
            is_pub: bool,
            /// Always `false` for `kind != .@"var"`.
            is_threadlocal: bool,
            /// Always `.normal` for `kind != .@"const" and kind != .@"var"`.
            linkage: Linkage,
            /// Always `.empty` for `linkage != .@"extern"`.
            lib_name: NullTerminatedString,

            /// Always populated for `linkage == .@"extern".
            type_body: ?[]const Inst.Index,
            align_body: ?[]const Inst.Index,
            linksection_body: ?[]const Inst.Index,
            addrspace_body: ?[]const Inst.Index,
            /// Always populated for `linkage != .@"extern".
            value_body: ?[]const Inst.Index,
        };

        pub const Flags = packed struct(u64) {
            src_line: u30,
            src_column: u29,
            id: Id,

            pub const Id = enum(u5) {
                unnamed_test,
                @"test",
                decltest,
                @"comptime",

                const_simple,
                const_typed,
                @"const",
                pub_const_simple,
                pub_const_typed,
                pub_const,

                extern_const_simple,
                extern_const,
                pub_extern_const_simple,
                pub_extern_const,

                export_const,
                pub_export_const,

                var_simple,
                @"var",
                var_threadlocal,
                pub_var_simple,
                pub_var,
                pub_var_threadlocal,

                extern_var,
                extern_var_threadlocal,
                pub_extern_var,
                pub_extern_var_threadlocal,

                export_var,
                export_var_threadlocal,
                pub_export_var,
                pub_export_var_threadlocal,

                pub fn hasName(id: Id) bool {
                    return switch (id) {
                        .unnamed_test,
                        .@"comptime",
                        => false,
                        else => true,
                    };
                }

                pub fn hasLibName(id: Id) bool {
                    return switch (id) {
                        .extern_const,
                        .pub_extern_const,
                        .extern_var,
                        .extern_var_threadlocal,
                        .pub_extern_var,
                        .pub_extern_var_threadlocal,
                        => true,
                        else => false,
                    };
                }

                pub fn hasTypeBody(id: Id) bool {
                    return switch (id) {
                        .unnamed_test,
                        .@"test",
                        .decltest,
                        .@"comptime",
                        => false, // these constructs are untyped
                        .const_simple,
                        .pub_const_simple,
                        .var_simple,
                        .pub_var_simple,
                        => false, // these reprs omit type bodies
                        else => true,
                    };
                }

                pub fn hasValueBody(id: Id) bool {
                    return switch (id) {
                        .extern_const_simple,
                        .extern_const,
                        .pub_extern_const_simple,
                        .pub_extern_const,
                        .extern_var,
                        .extern_var_threadlocal,
                        .pub_extern_var,
                        .pub_extern_var_threadlocal,
                        => false, // externs do not have values
                        else => true,
                    };
                }

                pub fn hasSpecialBodies(id: Id) bool {
                    return switch (id) {
                        .unnamed_test,
                        .@"test",
                        .decltest,
                        .@"comptime",
                        => false, // these constructs are untyped
                        .const_simple,
                        .const_typed,
                        .pub_const_simple,
                        .pub_const_typed,
                        .extern_const_simple,
                        .pub_extern_const_simple,
                        .var_simple,
                        .pub_var_simple,
                        => false, // these reprs omit special bodies
                        else => true,
                    };
                }

                pub fn linkage(id: Id) Declaration.Unwrapped.Linkage {
                    return switch (id) {
                        .extern_const_simple,
                        .extern_const,
                        .pub_extern_const_simple,
                        .pub_extern_const,
                        .extern_var,
                        .extern_var_threadlocal,
                        .pub_extern_var,
                        .pub_extern_var_threadlocal,
                        => .@"extern",
                        .export_const,
                        .pub_export_const,
                        .export_var,
                        .export_var_threadlocal,
                        .pub_export_var,
                        .pub_export_var_threadlocal,
                        => .@"export",
                        else => .normal,
                    };
                }

                pub fn kind(id: Id) Declaration.Unwrapped.Kind {
                    return switch (id) {
                        .unnamed_test => .unnamed_test,
                        .@"test" => .@"test",
                        .decltest => .decltest,
                        .@"comptime" => .@"comptime",
                        .const_simple,
                        .const_typed,
                        .@"const",
                        .pub_const_simple,
                        .pub_const_typed,
                        .pub_const,
                        .extern_const_simple,
                        .extern_const,
                        .pub_extern_const_simple,
                        .pub_extern_const,
                        .export_const,
                        .pub_export_const,
                        => .@"const",
                        .var_simple,
                        .@"var",
                        .var_threadlocal,
                        .pub_var_simple,
                        .pub_var,
                        .pub_var_threadlocal,
                        .extern_var,
                        .extern_var_threadlocal,
                        .pub_extern_var,
                        .pub_extern_var_threadlocal,
                        .export_var,
                        .export_var_threadlocal,
                        .pub_export_var,
                        .pub_export_var_threadlocal,
                        => .@"var",
                    };
                }

                pub fn isPub(id: Id) bool {
                    return switch (id) {
                        .pub_const_simple,
                        .pub_const_typed,
                        .pub_const,
                        .pub_extern_const_simple,
                        .pub_extern_const,
                        .pub_export_const,
                        .pub_var_simple,
                        .pub_var,
                        .pub_var_threadlocal,
                        .pub_extern_var,
                        .pub_extern_var_threadlocal,
                        .pub_export_var,
                        .pub_export_var_threadlocal,
                        => true,
                        else => false,
                    };
                }

                pub fn isThreadlocal(id: Id) bool {
                    return switch (id) {
                        .var_threadlocal,
                        .pub_var_threadlocal,
                        .extern_var_threadlocal,
                        .pub_extern_var_threadlocal,
                        .export_var_threadlocal,
                        .pub_export_var_threadlocal,
                        => true,
                        else => false,
                    };
                }
            };
        };

        pub const Name = enum(u32) {
            @"comptime" = std.math.maxInt(u32),
            unnamed_test = std.math.maxInt(u32) - 1,
            /// Other values are `NullTerminatedString` values, i.e. index into
            /// `string_bytes`. If the byte referenced is 0, the decl is a named
            /// test, and the actual name begins at the following byte.
            _,

            pub fn isNamedTest(name: Name, zir: Zir) bool {
                return switch (name) {
                    .@"comptime", .unnamed_test => false,
                    _ => zir.string_bytes[@intFromEnum(name)] == 0,
                };
            }
            pub fn toString(name: Name, zir: Zir) ?NullTerminatedString {
                switch (name) {
                    .@"comptime", .unnamed_test => return null,
                    _ => {},
                }
                const idx: u32 = @intFromEnum(name);
                if (zir.string_bytes[idx] == 0) {
                    // Named test
                    return @enumFromInt(idx + 1);
                }
                return @enumFromInt(idx);
            }
        };

        pub const Bodies = struct {
            type_body: ?[]const Index,
            align_body: ?[]const Index,
            linksection_body: ?[]const Index,
            addrspace_body: ?[]const Index,
            value_body: ?[]const Index,
        };

        pub fn getBodies(declaration: Declaration, extra_end: u32, zir: Zir) Bodies {
            var extra_index: u32 = extra_end;
            const value_body_len = declaration.value_body_len;
            const type_body_len: u32 = len: {
                if (!declaration.flags().kind.hasTypeBody()) break :len 0;
                const len = zir.extra[extra_index];
                extra_index += 1;
                break :len len;
            };
            const align_body_len, const linksection_body_len, const addrspace_body_len = lens: {
                if (!declaration.flags.kind.hasSpecialBodies()) {
                    break :lens .{ 0, 0, 0 };
                }
                const lens = zir.extra[extra_index..][0..3].*;
                extra_index += 3;
                break :lens lens;
            };
            return .{
                .type_body = if (type_body_len == 0) null else b: {
                    const b = zir.bodySlice(extra_index, type_body_len);
                    extra_index += type_body_len;
                    break :b b;
                },
                .align_body = if (align_body_len == 0) null else b: {
                    const b = zir.bodySlice(extra_index, align_body_len);
                    extra_index += align_body_len;
                    break :b b;
                },
                .linksection_body = if (linksection_body_len == 0) null else b: {
                    const b = zir.bodySlice(extra_index, linksection_body_len);
                    extra_index += linksection_body_len;
                    break :b b;
                },
                .addrspace_body = if (addrspace_body_len == 0) null else b: {
                    const b = zir.bodySlice(extra_index, addrspace_body_len);
                    extra_index += addrspace_body_len;
                    break :b b;
                },
                .value_body = if (value_body_len == 0) null else b: {
                    const b = zir.bodySlice(extra_index, value_body_len);
                    extra_index += value_body_len;
                    break :b b;
                },
            };
        }
    };

    /// Stored inside extra, with trailing arguments according to `args_len`.
    /// Implicit 0. arg_0_start: u32, // always same as `args_len`
    /// 1. arg_end: u32, // for each `args_len`
    /// arg_N_start is the same as arg_N-1_end
    pub const Call = struct {
        // Note: Flags *must* come first so that unusedResultExpr
        // can find it when it goes to modify them.
        flags: Flags,
        callee: Ref,

        pub const Flags = packed struct {
            /// std.builtin.CallModifier in packed form
            pub const PackedModifier = u3;
            pub const PackedArgsLen = u27;

            packed_modifier: PackedModifier,
            ensure_result_used: bool = false,
            pop_error_return_trace: bool,
            args_len: PackedArgsLen,

            comptime {
                if (@sizeOf(Flags) != 4 or @bitSizeOf(Flags) != 32)
                    @compileError("Layout of Call.Flags needs to be updated!");
                if (@bitSizeOf(std.builtin.CallModifier) != @bitSizeOf(PackedModifier))
                    @compileError("Call.Flags.PackedModifier needs to be updated!");
            }
        };
    };

    /// Stored inside extra, with trailing arguments according to `args_len`.
    /// Implicit 0. arg_0_start: u32, // always same as `args_len`
    /// 1. arg_end: u32, // for each `args_len`
    /// arg_N_start is the same as arg_N-1_end
    pub const FieldCall = struct {
        // Note: Flags *must* come first so that unusedResultExpr
        // can find it when it goes to modify them.
        flags: Call.Flags,
        obj_ptr: Ref,
        /// Offset into `string_bytes`.
        field_name_start: NullTerminatedString,
    };

    /// There is a body of instructions at `extra[body_index..][0..body_len]`.
    /// Trailing:
    /// 0. operand: Ref // for each `operands_len`
    pub const TypeOfPeer = struct {
        src_node: Ast.Node.Offset,
        body_len: u32,
        body_index: u32,
    };

    pub const BuiltinCall = struct {
        // Note: Flags *must* come first so that unusedResultExpr
        // can find it when it goes to modify them.
        flags: Flags,
        modifier: Ref,
        callee: Ref,
        args: Ref,

        pub const Flags = packed struct {
            is_nosuspend: bool,
            ensure_result_used: bool,
            _: u30 = undefined,

            comptime {
                if (@sizeOf(Flags) != 4 or @bitSizeOf(Flags) != 32)
                    @compileError("Layout of BuiltinCall.Flags needs to be updated!");
            }
        };
    };

    /// This data is stored inside extra, with two sets of trailing `Ref`:
    /// * 0. the then body, according to `then_body_len`.
    /// * 1. the else body, according to `else_body_len`.
    pub const CondBr = struct {
        condition: Ref,
        then_body_len: u32,
        else_body_len: u32,
    };

    /// This data is stored inside extra, trailed by:
    /// * 0. body: Index //  for each `body_len`.
    pub const Try = struct {
        /// The error union to unwrap.
        operand: Ref,
        body_len: u32,
    };

    /// Stored in extra. Depending on the flags in Data, there will be up to 5
    /// trailing Ref fields:
    /// 0. sentinel: Ref // if `has_sentinel` flag is set
    /// 1. align: Ref // if `has_align` flag is set
    /// 2. address_space: Ref // if `has_addrspace` flag is set
    /// 3. bit_start: Ref // if `has_bit_range` flag is set
    /// 4. host_size: Ref // if `has_bit_range` flag is set
    pub const PtrType = struct {
        elem_type: Ref,
        src_node: Ast.Node.Offset,
    };

    pub const ArrayTypeSentinel = struct {
        len: Ref,
        sentinel: Ref,
        elem_type: Ref,
    };

    pub const SliceStart = struct {
        lhs: Ref,
        start: Ref,
    };

    pub const SliceEnd = struct {
        lhs: Ref,
        start: Ref,
        end: Ref,
    };

    pub const SliceSentinel = struct {
        lhs: Ref,
        start: Ref,
        end: Ref,
        sentinel: Ref,
    };

    pub const SliceLength = struct {
        lhs: Ref,
        start: Ref,
        len: Ref,
        sentinel: Ref,
        start_src_node_offset: Ast.Node.Offset,
    };

    /// The meaning of these operands depends on the corresponding `Tag`.
    pub const Bin = struct {
        lhs: Ref,
        rhs: Ref,
    };

    pub const BinNode = struct {
        node: Ast.Node.Offset,
        lhs: Ref,
        rhs: Ref,
    };

    pub const UnNode = struct {
        node: Ast.Node.Offset,
        operand: Ref,
    };

    pub const ElemPtrImm = struct {
        ptr: Ref,
        index: u32,
    };

    pub const Reify = struct {
        /// This node is absolute, because `reify` instructions are tracked across updates, and
        /// this simplifies the logic for getting source locations for types.
        node: Ast.Node.Index,
        operand: Ref,
        src_line: u32,
    };

    /// Trailing:
    /// 0. multi_cases_len: u32 // if `has_multi_cases`
    /// 1. err_capture_inst: u32 // if `any_uses_err_capture`
    /// 2. non_err_body {
    ///        info: ProngInfo,
    ///        inst: Index // for every `info.body_len`
    ///     }
    /// 3. else_body { // if `has_else`
    ///        info: ProngInfo,
    ///        inst: Index // for every `info.body_len`
    ///     }
    /// 4. scalar_cases: { // for every `scalar_cases_len`
    ///        item: Ref,
    ///        info: ProngInfo,
    ///        inst: Index // for every `info.body_len`
    ///     }
    /// 5. multi_cases: { // for every `multi_cases_len`
    ///        items_len: u32,
    ///        ranges_len: u32,
    ///        info: ProngInfo,
    ///        item: Ref // for every `items_len`
    ///        ranges: { // for every `ranges_len`
    ///            item_first: Ref,
    ///            item_last: Ref,
    ///        }
    ///        inst: Index // for every `info.body_len`
    ///    }
    ///
    /// When analyzing a case body, the switch instruction itself refers to the
    /// captured error, or to the success value in `non_err_body`. Whether this
    /// is captured by reference or by value depends on whether the `byref` bit
    /// is set for the corresponding body. `err_capture_inst` refers to the error
    /// capture outside of the `switch`, i.e. `err` in
    /// `x catch |err| switch (err) { ... }`.
    pub const SwitchBlockErrUnion = struct {
        operand: Ref,
        bits: Bits,
        main_src_node_offset: Ast.Node.Offset,

        pub const Bits = packed struct(u32) {
            /// If true, one or more prongs have multiple items.
            has_multi_cases: bool,
            /// If true, there is an else prong. This is mutually exclusive with `has_under`.
            has_else: bool,
            any_uses_err_capture: bool,
            payload_is_ref: bool,
            scalar_cases_len: ScalarCasesLen,

            pub const ScalarCasesLen = u28;
        };

        pub const MultiProng = struct {
            items: []const Ref,
            body: []const Index,
        };
    };

    /// 0. multi_cases_len: u32 // If has_multi_cases is set.
    /// 1. tag_capture_inst: u32 // If any_has_tag_capture is set. Index of instruction prongs use to refer to the inline tag capture.
    /// 2. else_body { // If has_else or has_under is set.
    ///        info: ProngInfo,
    ///        body member Index for every info.body_len
    ///     }
    /// 3. scalar_cases: { // for every scalar_cases_len
    ///        item: Ref,
    ///        info: ProngInfo,
    ///        body member Index for every info.body_len
    ///     }
    /// 4. multi_cases: { // for every multi_cases_len
    ///        items_len: u32,
    ///        ranges_len: u32,
    ///        info: ProngInfo,
    ///        item: Ref // for every items_len
    ///        ranges: { // for every ranges_len
    ///            item_first: Ref,
    ///            item_last: Ref,
    ///        }
    ///        body member Index for every info.body_len
    ///    }
    ///
    /// When analyzing a case body, the switch instruction itself refers to the
    /// captured payload. Whether this is captured by reference or by value
    /// depends on whether the `byref` bit is set for the corresponding body.
    pub const SwitchBlock = struct {
        /// The operand passed to the `switch` expression. If this is a
        /// `switch_block`, this is the operand value; if `switch_block_ref` it
        /// is a pointer to the operand. `switch_block_ref` is always used if
        /// any prong has a byref capture.
        operand: Ref,
        bits: Bits,

        /// These are stored in trailing data in `extra` for each prong.
        pub const ProngInfo = packed struct(u32) {
            body_len: u28,
            capture: ProngInfo.Capture,
            is_inline: bool,
            has_tag_capture: bool,

            pub const Capture = enum(u2) {
                none,
                by_val,
                by_ref,
            };
        };

        pub const Bits = packed struct(u32) {
            /// If true, one or more prongs have multiple items.
            has_multi_cases: bool,
            /// If true, there is an else prong. This is mutually exclusive with `has_under`.
            has_else: bool,
            /// If true, there is an underscore prong. This is mutually exclusive with `has_else`.
            has_under: bool,
            /// If true, at least one prong has an inline tag capture.
            any_has_tag_capture: bool,
            /// If true, at least one prong has a capture which may not
            /// be comptime-known via `inline`.
            any_non_inline_capture: bool,
            has_continue: bool,
            scalar_cases_len: ScalarCasesLen,

            pub const ScalarCasesLen = u26;

            pub fn specialProng(bits: Bits) SpecialProng {
                const has_else: u2 = @intFromBool(bits.has_else);
                const has_under: u2 = @intFromBool(bits.has_under);
                return switch ((has_else << 1) | has_under) {
                    0b00 => .none,
                    0b01 => .under,
                    0b10 => .@"else",
                    0b11 => unreachable,
                };
            }
        };

        pub const MultiProng = struct {
            items: []const Ref,
            body: []const Index,
        };
    };

    pub const ArrayInitRefTy = struct {
        ptr_ty: Ref,
        elem_count: u32,
    };

    pub const Field = struct {
        lhs: Ref,
        /// Offset into `string_bytes`.
        field_name_start: NullTerminatedString,
    };

    pub const FieldNamed = struct {
        lhs: Ref,
        field_name: Ref,
    };

    pub const As = struct {
        dest_type: Ref,
        operand: Ref,
    };

    /// Trailing:
    /// 0. captures_len: u32 // if has_captures_len
    /// 1. fields_len: u32, // if has_fields_len
    /// 2. decls_len: u32, // if has_decls_len
    /// 3. capture: Capture // for every captures_len
    /// 4. capture_name: NullTerminatedString // for every captures_len
    /// 5. backing_int_body_len: u32, // if has_backing_int
    /// 6. backing_int_ref: Ref, // if has_backing_int and backing_int_body_len is 0
    /// 7. backing_int_body_inst: Inst, // if has_backing_int and backing_int_body_len is > 0
    /// 8. decl: Index, // for every decls_len; points to a `declaration` instruction
    /// 9. flags: u32 // for every 8 fields
    ///    - sets of 4 bits:
    ///      0b000X: whether corresponding field has an align expression
    ///      0b00X0: whether corresponding field has a default expression
    ///      0b0X00: whether corresponding field is comptime
    ///      0bX000: whether corresponding field has a type expression
    /// 10. fields: { // for every fields_len
    ///        field_name: u32,
    ///        field_type: Ref, // if corresponding bit is not set. none means anytype.
    ///        field_type_body_len: u32, // if corresponding bit is set
    ///        align_body_len: u32, // if corresponding bit is set
    ///        init_body_len: u32, // if corresponding bit is set
    ///    }
    /// 11. bodies: { // for every fields_len
    ///        field_type_body_inst: Inst, // for each field_type_body_len
    ///        align_body_inst: Inst, // for each align_body_len
    ///        init_body_inst: Inst, // for each init_body_len
    ///    }
    pub const StructDecl = struct {
        // These fields should be concatenated and reinterpreted as a `std.zig.SrcHash`.
        // This hash contains the source of all fields, and any specified attributes (`extern`, backing type, etc).
        fields_hash_0: u32,
        fields_hash_1: u32,
        fields_hash_2: u32,
        fields_hash_3: u32,
        src_line: u32,
        /// This node provides a new absolute baseline node for all instructions within this struct.
        src_node: Ast.Node.Index,

        pub const Small = packed struct {
            has_captures_len: bool,
            has_fields_len: bool,
            has_decls_len: bool,
            has_backing_int: bool,
            known_non_opv: bool,
            known_comptime_only: bool,
            name_strategy: NameStrategy,
            layout: std.builtin.Type.ContainerLayout,
            any_default_inits: bool,
            any_comptime_fields: bool,
            any_aligned_fields: bool,
            _: u3 = undefined,
        };
    };

    /// Represents a single value being captured in a type declaration's closure.
    pub const Capture = packed struct(u32) {
        tag: enum(u3) {
            /// `data` is a `u16` index into the parent closure.
            nested,
            /// `data` is a `Zir.Inst.Index` to an instruction whose value is being captured.
            instruction,
            /// `data` is a `Zir.Inst.Index` to an instruction representing an alloc whose contents is being captured.
            instruction_load,
            /// `data` is a `NullTerminatedString` to a decl name.
            decl_val,
            /// `data` is a `NullTerminatedString` to a decl name.
            decl_ref,
        },
        data: u29,
        pub const Unwrapped = union(enum) {
            nested: u16,
            instruction: Zir.Inst.Index,
            instruction_load: Zir.Inst.Index,
            decl_val: NullTerminatedString,
            decl_ref: NullTerminatedString,
        };
        pub fn wrap(cap: Unwrapped) Capture {
            return switch (cap) {
                .nested => |idx| .{
                    .tag = .nested,
                    .data = idx,
                },
                .instruction => |inst| .{
                    .tag = .instruction,
                    .data = @intCast(@intFromEnum(inst)),
                },
                .instruction_load => |inst| .{
                    .tag = .instruction_load,
                    .data = @intCast(@intFromEnum(inst)),
                },
                .decl_val => |str| .{
                    .tag = .decl_val,
                    .data = @intCast(@intFromEnum(str)),
                },
                .decl_ref => |str| .{
                    .tag = .decl_ref,
                    .data = @intCast(@intFromEnum(str)),
                },
            };
        }
        pub fn unwrap(cap: Capture) Unwrapped {
            return switch (cap.tag) {
                .nested => .{ .nested = @intCast(cap.data) },
                .instruction => .{ .instruction = @enumFromInt(cap.data) },
                .instruction_load => .{ .instruction_load = @enumFromInt(cap.data) },
                .decl_val => .{ .decl_val = @enumFromInt(cap.data) },
                .decl_ref => .{ .decl_ref = @enumFromInt(cap.data) },
            };
        }
    };

    pub const NameStrategy = enum(u2) {
        /// Use the same name as the parent declaration name.
        /// e.g. `const Foo = struct {...};`.
        parent,
        /// Use the name of the currently executing comptime function call,
        /// with the current parameters. e.g. `ArrayList(i32)`.
        func,
        /// Create an anonymous name for this declaration.
        /// Like this: "ParentDeclName_struct_69"
        anon,
        /// Use the name specified in the next `dbg_var_{val,ptr}` instruction.
        dbg_var,
    };

    pub const FullPtrCastFlags = packed struct(u5) {
        ptr_cast: bool = false,
        align_cast: bool = false,
        addrspace_cast: bool = false,
        const_cast: bool = false,
        volatile_cast: bool = false,

        pub inline fn needResultTypeBuiltinName(flags: FullPtrCastFlags) []const u8 {
            if (flags.ptr_cast) return "@ptrCast";
            if (flags.align_cast) return "@alignCast";
            if (flags.addrspace_cast) return "@addrSpaceCast";
            unreachable;
        }
    };

    pub const BuiltinValue = enum(u16) {
        // Types
        atomic_order,
        atomic_rmw_op,
        calling_convention,
        address_space,
        float_mode,
        reduce_op,
        call_modifier,
        prefetch_options,
        export_options,
        extern_options,
        type_info,
        branch_hint,
        clobbers,
        // Values
        calling_convention_c,
        calling_convention_inline,
    };

    pub const InplaceOp = enum(u16) {
        add_eq,
        sub_eq,
    };

    /// Trailing:
    /// 0. tag_type: Ref, // if has_tag_type
    /// 1. captures_len: u32, // if has_captures_len
    /// 2. body_len: u32, // if has_body_len
    /// 3. fields_len: u32, // if has_fields_len
    /// 4. decls_len: u32, // if has_decls_len
    /// 5. capture: Capture // for every captures_len
    /// 6. capture_name: NullTerminatedString // for every captures_len
    /// 7. decl: Index, // for every decls_len; points to a `declaration` instruction
    /// 8. inst: Index // for every body_len
    /// 9. has_bits: u32 // for every 32 fields
    ///    - the bit is whether corresponding field has an value expression
    /// 10. fields: { // for every fields_len
    ///        field_name: u32,
    ///        value: Ref, // if corresponding bit is set
    ///    }
    pub const EnumDecl = struct {
        // These fields should be concatenated and reinterpreted as a `std.zig.SrcHash`.
        // This hash contains the source of all fields, and the backing type if specified.
        fields_hash_0: u32,
        fields_hash_1: u32,
        fields_hash_2: u32,
        fields_hash_3: u32,
        src_line: u32,
        /// This node provides a new absolute baseline node for all instructions within this struct.
        src_node: Ast.Node.Index,

        pub const Small = packed struct {
            has_tag_type: bool,
            has_captures_len: bool,
            has_body_len: bool,
            has_fields_len: bool,
            has_decls_len: bool,
            name_strategy: NameStrategy,
            nonexhaustive: bool,
            _: u8 = undefined,
        };
    };

    /// Trailing:
    /// 0. tag_type: Ref, // if has_tag_type
    /// 1. captures_len: u32 // if has_captures_len
    /// 2. body_len: u32, // if has_body_len
    /// 3. fields_len: u32, // if has_fields_len
    /// 4. decls_len: u32, // if has_decls_len
    /// 5. capture: Capture // for every captures_len
    /// 6. capture_name: NullTerminatedString // for every captures_len
    /// 7. decl: Index, // for every decls_len; points to a `declaration` instruction
    /// 8. inst: Index // for every body_len
    /// 9. has_bits: u32 // for every 8 fields
    ///    - sets of 4 bits:
    ///      0b000X: whether corresponding field has a type expression
    ///      0b00X0: whether corresponding field has a align expression
    ///      0b0X00: whether corresponding field has a tag value expression
    ///      0bX000: unused
    /// 10. fields: { // for every fields_len
    ///        field_name: NullTerminatedString, // null terminated string index
    ///        field_type: Ref, // if corresponding bit is set
    ///        align: Ref, // if corresponding bit is set
    ///        tag_value: Ref, // if corresponding bit is set
    ///    }
    pub const UnionDecl = struct {
        // These fields should be concatenated and reinterpreted as a `std.zig.SrcHash`.
        // This hash contains the source of all fields, and any specified attributes (`extern` etc).
        fields_hash_0: u32,
        fields_hash_1: u32,
        fields_hash_2: u32,
        fields_hash_3: u32,
        src_line: u32,
        /// This node provides a new absolute baseline node for all instructions within this struct.
        src_node: Ast.Node.Index,

        pub const Small = packed struct {
            has_tag_type: bool,
            has_captures_len: bool,
            has_body_len: bool,
            has_fields_len: bool,
            has_decls_len: bool,
            name_strategy: NameStrategy,
            layout: std.builtin.Type.ContainerLayout,
            /// has_tag_type | auto_enum_tag | result
            /// -------------------------------------
            ///    false     | false         |  union { }
            ///    false     | true          |  union(enum) { }
            ///    true      | true          |  union(enum(T)) { }
            ///    true      | false         |  union(T) { }
            auto_enum_tag: bool,
            any_aligned_fields: bool,
            _: u5 = undefined,
        };
    };

    /// Trailing:
    /// 0. captures_len: u32, // if has_captures_len
    /// 1. decls_len: u32, // if has_decls_len
    /// 2. capture: Capture, // for every captures_len
    /// 3. capture_name: NullTerminatedString // for every captures_len
    /// 4. decl: Index, // for every decls_len; points to a `declaration` instruction
    pub const OpaqueDecl = struct {
        src_line: u32,
        /// This node provides a new absolute baseline node for all instructions within this struct.
        src_node: Ast.Node.Index,

        pub const Small = packed struct {
            has_captures_len: bool,
            has_decls_len: bool,
            name_strategy: NameStrategy,
            _: u12 = undefined,
        };
    };

    /// Trailing:
    /// 1. fields: { // for every `fields_len` (stored in `extended.small`)
    ///        type: Inst.Ref,
    ///        init: Inst.Ref, // `.none` for non-`comptime` fields
    ///    }
    pub const TupleDecl = struct {
        src_node: Ast.Node.Offset,
    };

    /// Trailing:
    /// 0. field_name: NullTerminatedString // for every fields_len
    pub const ErrorSetDecl = struct {
        fields_len: u32,
    };

    /// A f128 value, broken up into 4 u32 parts.
    pub const Float128 = struct {
        piece0: u32,
        piece1: u32,
        piece2: u32,
        piece3: u32,

        pub fn get(self: Float128) f128 {
            const int_bits = @as(u128, self.piece0) |
                (@as(u128, self.piece1) << 32) |
                (@as(u128, self.piece2) << 64) |
                (@as(u128, self.piece3) << 96);
            return @as(f128, @bitCast(int_bits));
        }
    };

    /// Trailing is an item per field.
    pub const StructInit = struct {
        /// If this is an anonymous initialization (the operand is poison), this instruction becomes the owner of a type.
        /// To resolve source locations, we need an absolute source node.
        abs_node: Ast.Node.Index,
        /// Likewise, we need an absolute line number.
        abs_line: u32,
        fields_len: u32,

        pub const Item = struct {
            /// The `struct_init_field_type` ZIR instruction for this field init.
            field_type: Index,
            /// The field init expression to be used as the field value. This value will be coerced
            /// to the field type if not already.
            init: Ref,
        };
    };

    /// Trailing is an Item per field.
    /// TODO make this instead array of inits followed by array of names because
    /// it will be simpler Sema code and better for CPU cache.
    pub const StructInitAnon = struct {
        /// This is an anonymous initialization, meaning this instruction becomes the owner of a type.
        /// To resolve source locations, we need an absolute source node.
        abs_node: Ast.Node.Index,
        /// Likewise, we need an absolute line number.
        abs_line: u32,
        fields_len: u32,

        pub const Item = struct {
            /// Null-terminated string table index.
            field_name: NullTerminatedString,
            /// The field init expression to be used as the field value.
            init: Ref,
        };
    };

    pub const FieldType = struct {
        container_type: Ref,
        /// Offset into `string_bytes`, null terminated.
        name_start: NullTerminatedString,
    };

    pub const FieldTypeRef = struct {
        container_type: Ref,
        field_name: Ref,
    };

    pub const Cmpxchg = struct {
        node: Ast.Node.Offset,
        ptr: Ref,
        expected_value: Ref,
        new_value: Ref,
        success_order: Ref,
        failure_order: Ref,
    };

    pub const AtomicRmw = struct {
        ptr: Ref,
        operation: Ref,
        operand: Ref,
        ordering: Ref,
    };

    pub const UnionInit = struct {
        union_type: Ref,
        field_name: Ref,
        init: Ref,
    };

    pub const AtomicStore = struct {
        ptr: Ref,
        operand: Ref,
        ordering: Ref,
    };

    pub const AtomicLoad = struct {
        elem_type: Ref,
        ptr: Ref,
        ordering: Ref,
    };

    pub const MulAdd = struct {
        mulend1: Ref,
        mulend2: Ref,
        addend: Ref,
    };

    pub const FieldParentPtr = struct {
        src_node: Ast.Node.Offset,
        parent_ptr_type: Ref,
        field_name: Ref,
        field_ptr: Ref,
    };

    pub const Shuffle = struct {
        elem_type: Ref,
        a: Ref,
        b: Ref,
        mask: Ref,
    };

    pub const Select = struct {
        node: Ast.Node.Offset,
        elem_type: Ref,
        pred: Ref,
        a: Ref,
        b: Ref,
    };

    /// Trailing: inst: Index // for every body_len
    pub const Param = struct {
        /// Null-terminated string index.
        name: NullTerminatedString,
        type: Type,

        pub const Type = packed struct(u32) {
            /// The body contains the type of the parameter.
            body_len: u31,
            /// Whether the type is generic, i.e. refers to one or more previous parameters.
            is_generic: bool,
        };
    };

    /// Trailing:
    /// 0. type_inst: Ref,  // if small 0b000X is set
    /// 1. align_inst: Ref, // if small 0b00X0 is set
    pub const AllocExtended = struct {
        src_node: Ast.Node.Offset,

        pub const Small = packed struct {
            has_type: bool,
            has_align: bool,
            is_const: bool,
            is_comptime: bool,
            _: u12 = undefined,
        };
    };

    pub const Export = struct {
        exported: Ref,
        options: Ref,
    };

    /// Trailing: `CompileErrors.Item` for each `items_len`.
    pub const CompileErrors = struct {
        items_len: u32,

        /// Trailing: `note_payload_index: u32` for each `notes_len`.
        /// It's a payload index of another `Item`.
        pub const Item = struct {
            /// null terminated string index
            msg: NullTerminatedString,
            node: Ast.Node.OptionalIndex,
            /// If node is .none then this will be populated.
            token: Ast.OptionalTokenIndex,
            /// Can be used in combination with `token`.
            byte_offset: u32,
            /// 0 or a payload index of a `Block`, each is a payload
            /// index of another `Item`.
            notes: u32,

            pub fn notesLen(item: Item, zir: Zir) u32 {
                if (item.notes == 0) return 0;
                const block = zir.extraData(Block, item.notes);
                return block.data.body_len;
            }
        };
    };

    /// Trailing: for each `imports_len` there is an Item
    pub const Imports = struct {
        imports_len: u32,

        pub const Item = struct {
            /// null terminated string index
            name: NullTerminatedString,
            /// points to the import name
            token: Ast.TokenIndex,
        };
    };

    pub const LineColumn = struct {
        line: u32,
        column: u32,
    };

    pub const ArrayInit = struct {
        ty: Ref,
        init_count: u32,
    };

    pub const Src = struct {
        node: Ast.Node.Offset,
        line: u32,
        column: u32,
    };

    pub const DeferErrCode = struct {
        remapped_err_code: Index,
        index: u32,
        len: u32,
    };

    pub const ValidateDestructure = struct {
        /// The value being destructured.
        operand: Ref,
        /// The `destructure_assign` node.
        destructure_node: Ast.Node.Offset,
        /// The expected field count.
        expect_len: u32,
    };

    pub const ArrayMul = struct {
        /// The result type of the array multiplication operation, or `.none` if none was available.
        res_ty: Ref,
        /// The LHS of the array multiplication.
        lhs: Ref,
        /// The RHS of the array multiplication.
        rhs: Ref,
    };

    pub const RestoreErrRetIndex = struct {
        src_node: Ast.Node.Offset,
        /// If `.none`, restore the trace to its state upon function entry.
        block: Ref,
        /// If `.none`, restore unconditionally.
        operand: Ref,
    };

    pub const Import = struct {
        /// The result type of the import, or `.none` if none was available.
        res_ty: Ref,
        /// The import path.
        path: NullTerminatedString,
    };
};

pub const SpecialProng = enum { none, @"else", under };

pub const DeclIterator = struct {
    extra_index: u32,
    decls_remaining: u32,
    zir: Zir,

    pub fn next(it: *DeclIterator) ?Inst.Index {
        if (it.decls_remaining == 0) return null;
        const decl_inst: Zir.Inst.Index = @enumFromInt(it.zir.extra[it.extra_index]);
        it.extra_index += 1;
        it.decls_remaining -= 1;
        assert(it.zir.instructions.items(.tag)[@intFromEnum(decl_inst)] == .declaration);
        return decl_inst;
    }
};

pub fn declIterator(zir: Zir, decl_inst: Zir.Inst.Index) DeclIterator {
    const inst = zir.instructions.get(@intFromEnum(decl_inst));
    assert(inst.tag == .extended);
    const extended = inst.data.extended;
    switch (extended.opcode) {
        .struct_decl => {
            const small: Inst.StructDecl.Small = @bitCast(extended.small);
            var extra_index: u32 = @intCast(extended.operand + @typeInfo(Inst.StructDecl).@"struct".fields.len);
            const captures_len = if (small.has_captures_len) captures_len: {
                const captures_len = zir.extra[extra_index];
                extra_index += 1;
                break :captures_len captures_len;
            } else 0;
            extra_index += @intFromBool(small.has_fields_len);
            const decls_len = if (small.has_decls_len) decls_len: {
                const decls_len = zir.extra[extra_index];
                extra_index += 1;
                break :decls_len decls_len;
            } else 0;

            extra_index += captures_len * 2;

            if (small.has_backing_int) {
                const backing_int_body_len = zir.extra[extra_index];
                extra_index += 1; // backing_int_body_len
                if (backing_int_body_len == 0) {
                    extra_index += 1; // backing_int_ref
                } else {
                    extra_index += backing_int_body_len; // backing_int_body_inst
                }
            }

            return .{
                .extra_index = extra_index,
                .decls_remaining = decls_len,
                .zir = zir,
            };
        },
        .enum_decl => {
            const small: Inst.EnumDecl.Small = @bitCast(extended.small);
            var extra_index: u32 = @intCast(extended.operand + @typeInfo(Inst.EnumDecl).@"struct".fields.len);
            extra_index += @intFromBool(small.has_tag_type);
            const captures_len = if (small.has_captures_len) captures_len: {
                const captures_len = zir.extra[extra_index];
                extra_index += 1;
                break :captures_len captures_len;
            } else 0;
            extra_index += @intFromBool(small.has_body_len);
            extra_index += @intFromBool(small.has_fields_len);
            const decls_len = if (small.has_decls_len) decls_len: {
                const decls_len = zir.extra[extra_index];
                extra_index += 1;
                break :decls_len decls_len;
            } else 0;

            extra_index += captures_len * 2;

            return .{
                .extra_index = extra_index,
                .decls_remaining = decls_len,
                .zir = zir,
            };
        },
        .union_decl => {
            const small: Inst.UnionDecl.Small = @bitCast(extended.small);
            var extra_index: u32 = @intCast(extended.operand + @typeInfo(Inst.UnionDecl).@"struct".fields.len);
            extra_index += @intFromBool(small.has_tag_type);
            const captures_len = if (small.has_captures_len) captures_len: {
                const captures_len = zir.extra[extra_index];
                extra_index += 1;
                break :captures_len captures_len;
            } else 0;
            extra_index += @intFromBool(small.has_body_len);
            extra_index += @intFromBool(small.has_fields_len);
            const decls_len = if (small.has_decls_len) decls_len: {
                const decls_len = zir.extra[extra_index];
                extra_index += 1;
                break :decls_len decls_len;
            } else 0;

            extra_index += captures_len * 2;

            return .{
                .extra_index = extra_index,
                .decls_remaining = decls_len,
                .zir = zir,
            };
        },
        .opaque_decl => {
            const small: Inst.OpaqueDecl.Small = @bitCast(extended.small);
            var extra_index: u32 = @intCast(extended.operand + @typeInfo(Inst.OpaqueDecl).@"struct".fields.len);
            const decls_len = if (small.has_decls_len) decls_len: {
                const decls_len = zir.extra[extra_index];
                extra_index += 1;
                break :decls_len decls_len;
            } else 0;
            const captures_len = if (small.has_captures_len) captures_len: {
                const captures_len = zir.extra[extra_index];
                extra_index += 1;
                break :captures_len captures_len;
            } else 0;

            extra_index += captures_len * 2;

            return .{
                .extra_index = extra_index,
                .decls_remaining = decls_len,
                .zir = zir,
            };
        },
        else => unreachable,
    }
}

/// `DeclContents` contains all "interesting" instructions found within a declaration by `findTrackable`.
/// These instructions are partitioned into a few different sets, since this makes ZIR instruction mapping
/// more effective.
pub const DeclContents = struct {
    /// This is a simple optional because ZIR guarantees that a `func`/`func_inferred`/`func_fancy` instruction
    /// can only occur once per `declaration`.
    func_decl: ?Inst.Index,
    explicit_types: std.ArrayListUnmanaged(Inst.Index),
    other: std.ArrayListUnmanaged(Inst.Index),

    pub const init: DeclContents = .{
        .func_decl = null,
        .explicit_types = .empty,
        .other = .empty,
    };

    pub fn clear(contents: *DeclContents) void {
        contents.func_decl = null;
        contents.explicit_types.clearRetainingCapacity();
        contents.other.clearRetainingCapacity();
    }

    pub fn deinit(contents: *DeclContents, gpa: Allocator) void {
        contents.explicit_types.deinit(gpa);
        contents.other.deinit(gpa);
    }
};

/// Find all tracked ZIR instructions, recursively, within a `declaration` instruction. Does not recurse through
/// nested declarations; to find all declarations, call this function recursively on the type declarations discovered
/// in `contents.explicit_types`.
///
/// This populates an `ArrayListUnmanaged` because an iterator would need to allocate memory anyway.
pub fn findTrackable(zir: Zir, gpa: Allocator, contents: *DeclContents, decl_inst: Zir.Inst.Index) !void {
    contents.clear();

    const decl = zir.getDeclaration(decl_inst);

    // `defer` instructions duplicate the same body arbitrarily many times, but we only want to traverse
    // their contents once per defer. So, we store the extra index of the body here to deduplicate.
    var found_defers: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer found_defers.deinit(gpa);

    if (decl.type_body) |b| try zir.findTrackableBody(gpa, contents, &found_defers, b);
    if (decl.align_body) |b| try zir.findTrackableBody(gpa, contents, &found_defers, b);
    if (decl.linksection_body) |b| try zir.findTrackableBody(gpa, contents, &found_defers, b);
    if (decl.addrspace_body) |b| try zir.findTrackableBody(gpa, contents, &found_defers, b);
    if (decl.value_body) |b| try zir.findTrackableBody(gpa, contents, &found_defers, b);
}

/// Like `findTrackable`, but only considers the `main_struct_inst` instruction. This may return more than
/// just that instruction because it will also traverse fields.
pub fn findTrackableRoot(zir: Zir, gpa: Allocator, contents: *DeclContents) !void {
    contents.clear();

    var found_defers: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer found_defers.deinit(gpa);

    try zir.findTrackableInner(gpa, contents, &found_defers, .main_struct_inst);
}

fn findTrackableInner(
    zir: Zir,
    gpa: Allocator,
    contents: *DeclContents,
    defers: *std.AutoHashMapUnmanaged(u32, void),
    inst: Inst.Index,
) Allocator.Error!void {
    comptime assert(Zir.inst_tracking_version == 0);

    const tags = zir.instructions.items(.tag);
    const datas = zir.instructions.items(.data);

    switch (tags[@intFromEnum(inst)]) {
        .declaration => unreachable,

        // Boring instruction tags first. These have no body and are not declarations or type declarations.
        .add,
        .addwrap,
        .add_sat,
        .add_unsafe,
        .sub,
        .subwrap,
        .sub_sat,
        .mul,
        .mulwrap,
        .mul_sat,
        .div_exact,
        .div_floor,
        .div_trunc,
        .mod,
        .rem,
        .mod_rem,
        .shl,
        .shl_exact,
        .shl_sat,
        .shr,
        .shr_exact,
        .param_anytype,
        .param_anytype_comptime,
        .array_cat,
        .array_mul,
        .array_type,
        .array_type_sentinel,
        .vector_type,
        .elem_type,
        .indexable_ptr_elem_type,
        .vec_arr_elem_type,
        .indexable_ptr_len,
        .anyframe_type,
        .as_node,
        .as_shift_operand,
        .bit_and,
        .bitcast,
        .bit_not,
        .bit_or,
        .bool_not,
        .bool_br_and,
        .bool_br_or,
        .@"break",
        .break_inline,
        .switch_continue,
        .check_comptime_control_flow,
        .builtin_call,
        .cmp_lt,
        .cmp_lte,
        .cmp_eq,
        .cmp_gte,
        .cmp_gt,
        .cmp_neq,
        .error_set_decl,
        .dbg_stmt,
        .dbg_var_ptr,
        .dbg_var_val,
        .decl_ref,
        .decl_val,
        .load,
        .div,
        .elem_ptr_node,
        .elem_ptr,
        .elem_val_node,
        .elem_val,
        .elem_val_imm,
        .ensure_result_used,
        .ensure_result_non_error,
        .ensure_err_union_payload_void,
        .error_union_type,
        .error_value,
        .@"export",
        .field_ptr,
        .field_val,
        .field_ptr_named,
        .field_val_named,
        .import,
        .int,
        .int_big,
        .float,
        .float128,
        .int_type,
        .is_non_null,
        .is_non_null_ptr,
        .is_non_err,
        .is_non_err_ptr,
        .ret_is_non_err,
        .repeat,
        .repeat_inline,
        .for_len,
        .merge_error_sets,
        .ref,
        .ret_node,
        .ret_load,
        .ret_implicit,
        .ret_err_value,
        .ret_err_value_code,
        .ret_ptr,
        .ret_type,
        .ptr_type,
        .slice_start,
        .slice_end,
        .slice_sentinel,
        .slice_length,
        .slice_sentinel_ty,
        .store_node,
        .store_to_inferred_ptr,
        .str,
        .negate,
        .negate_wrap,
        .typeof,
        .typeof_log2_int_type,
        .@"unreachable",
        .xor,
        .optional_type,
        .optional_payload_safe,
        .optional_payload_unsafe,
        .optional_payload_safe_ptr,
        .optional_payload_unsafe_ptr,
        .err_union_payload_unsafe,
        .err_union_payload_unsafe_ptr,
        .err_union_code,
        .err_union_code_ptr,
        .enum_literal,
        .decl_literal,
        .decl_literal_no_coerce,
        .validate_deref,
        .validate_destructure,
        .field_type_ref,
        .opt_eu_base_ptr_init,
        .coerce_ptr_elem_ty,
        .validate_ref_ty,
        .validate_const,
        .struct_init_empty,
        .struct_init_empty_result,
        .struct_init_empty_ref_result,
        .validate_struct_init_ty,
        .validate_struct_init_result_ty,
        .validate_ptr_struct_init,
        .struct_init_field_type,
        .struct_init_field_ptr,
        .array_init_anon,
        .array_init,
        .array_init_ref,
        .validate_array_init_ty,
        .validate_array_init_result_ty,
        .validate_array_init_ref_ty,
        .validate_ptr_array_init,
        .array_init_elem_type,
        .array_init_elem_ptr,
        .union_init,
        .type_info,
        .size_of,
        .bit_size_of,
        .int_from_ptr,
        .compile_error,
        .set_eval_branch_quota,
        .int_from_enum,
        .align_of,
        .int_from_bool,
        .embed_file,
        .error_name,
        .panic,
        .trap,
        .set_runtime_safety,
        .sqrt,
        .sin,
        .cos,
        .tan,
        .exp,
        .exp2,
        .log,
        .log2,
        .log10,
        .abs,
        .floor,
        .ceil,
        .trunc,
        .round,
        .tag_name,
        .type_name,
        .frame_type,
        .int_from_float,
        .float_from_int,
        .ptr_from_int,
        .enum_from_int,
        .float_cast,
        .int_cast,
        .ptr_cast,
        .truncate,
        .has_decl,
        .has_field,
        .clz,
        .ctz,
        .pop_count,
        .byte_swap,
        .bit_reverse,
        .bit_offset_of,
        .offset_of,
        .splat,
        .reduce,
        .shuffle,
        .atomic_load,
        .atomic_rmw,
        .atomic_store,
        .mul_add,
        .memcpy,
        .memset,
        .memmove,
        .min,
        .max,
        .alloc,
        .alloc_mut,
        .alloc_comptime_mut,
        .alloc_inferred,
        .alloc_inferred_mut,
        .alloc_inferred_comptime,
        .alloc_inferred_comptime_mut,
        .resolve_inferred_alloc,
        .make_ptr_const,
        .@"resume",
        .save_err_ret_index,
        .restore_err_ret_index_unconditional,
        .restore_err_ret_index_fn_entry,
        => return,

        // Struct initializations need tracking, as they may create anonymous struct types.
        .struct_init,
        .struct_init_ref,
        .struct_init_anon,
        => return contents.other.append(gpa, inst),

        .extended => {
            const extended = datas[@intFromEnum(inst)].extended;
            switch (extended.opcode) {
                .value_placeholder => unreachable,

                // Once again, we start with the boring tags.
                .this,
                .ret_addr,
                .builtin_src,
                .error_return_trace,
                .frame,
                .frame_address,
                .alloc,
                .builtin_extern,
                .@"asm",
                .asm_expr,
                .compile_log,
                .min_multi,
                .max_multi,
                .add_with_overflow,
                .sub_with_overflow,
                .mul_with_overflow,
                .shl_with_overflow,
                .c_undef,
                .c_include,
                .c_define,
                .wasm_memory_size,
                .wasm_memory_grow,
                .prefetch,
                .set_float_mode,
                .error_cast,
                .breakpoint,
                .disable_instrumentation,
                .disable_intrinsics,
                .select,
                .int_from_error,
                .error_from_int,
                .cmpxchg,
                .c_va_arg,
                .c_va_copy,
                .c_va_end,
                .c_va_start,
                .ptr_cast_full,
                .ptr_cast_no_dest,
                .work_item_id,
                .work_group_size,
                .work_group_id,
                .in_comptime,
                .restore_err_ret_index,
                .closure_get,
                .field_parent_ptr,
                .builtin_value,
                .branch_hint,
                .inplace_arith_result_ty,
                .tuple_decl,
                .dbg_empty_stmt,
                .astgen_error,
                => return,

                // `@TypeOf` has a body.
                .typeof_peer => {
                    const extra = zir.extraData(Zir.Inst.TypeOfPeer, extended.operand);
                    const body = zir.bodySlice(extra.data.body_index, extra.data.body_len);
                    try zir.findTrackableBody(gpa, contents, defers, body);
                },

                // Reifications and opaque declarations need tracking, but have no body.
                .reify, .opaque_decl => return contents.other.append(gpa, inst),

                // Struct declarations need tracking and have bodies.
                .struct_decl => {
                    try contents.explicit_types.append(gpa, inst);

                    const small: Zir.Inst.StructDecl.Small = @bitCast(extended.small);
                    const extra = zir.extraData(Zir.Inst.StructDecl, extended.operand);
                    var extra_index = extra.end;
                    const captures_len = if (small.has_captures_len) blk: {
                        const captures_len = zir.extra[extra_index];
                        extra_index += 1;
                        break :blk captures_len;
                    } else 0;
                    const fields_len = if (small.has_fields_len) blk: {
                        const fields_len = zir.extra[extra_index];
                        extra_index += 1;
                        break :blk fields_len;
                    } else 0;
                    const decls_len = if (small.has_decls_len) blk: {
                        const decls_len = zir.extra[extra_index];
                        extra_index += 1;
                        break :blk decls_len;
                    } else 0;
                    extra_index += captures_len * 2;
                    if (small.has_backing_int) {
                        const backing_int_body_len = zir.extra[extra_index];
                        extra_index += 1;
                        if (backing_int_body_len == 0) {
                            extra_index += 1; // backing_int_ref
                        } else {
                            const body = zir.bodySlice(extra_index, backing_int_body_len);
                            extra_index += backing_int_body_len;
                            try zir.findTrackableBody(gpa, contents, defers, body);
                        }
                    }
                    extra_index += decls_len;

                    // This ZIR is structured in a slightly awkward way, so we have to split up the iteration.
                    // `extra_index` iterates `flags` (bags of bits).
                    // `fields_extra_index` iterates `fields`.
                    // We accumulate the total length of bodies into `total_bodies_len`. This is sufficient because
                    // the bodies are packed together in `extra` and we only need to traverse their instructions (we
                    // don't really care about the structure).

                    const bits_per_field = 4;
                    const fields_per_u32 = 32 / bits_per_field;
                    const bit_bags_count = std.math.divCeil(usize, fields_len, fields_per_u32) catch unreachable;
                    var cur_bit_bag: u32 = undefined;

                    var fields_extra_index = extra_index + bit_bags_count;
                    var total_bodies_len: u32 = 0;

                    for (0..fields_len) |field_i| {
                        if (field_i % fields_per_u32 == 0) {
                            cur_bit_bag = zir.extra[extra_index];
                            extra_index += 1;
                        }

                        const has_align = @as(u1, @truncate(cur_bit_bag)) != 0;
                        cur_bit_bag >>= 1;
                        const has_init = @as(u1, @truncate(cur_bit_bag)) != 0;
                        cur_bit_bag >>= 2; // also skip `is_comptime`; we don't care
                        const has_type_body = @as(u1, @truncate(cur_bit_bag)) != 0;
                        cur_bit_bag >>= 1;

                        fields_extra_index += 1; // field_name

                        if (has_type_body) {
                            const field_type_body_len = zir.extra[fields_extra_index];
                            total_bodies_len += field_type_body_len;
                        }
                        fields_extra_index += 1; // field_type or field_type_body_len

                        if (has_align) {
                            const align_body_len = zir.extra[fields_extra_index];
                            fields_extra_index += 1;
                            total_bodies_len += align_body_len;
                        }

                        if (has_init) {
                            const init_body_len = zir.extra[fields_extra_index];
                            fields_extra_index += 1;
                            total_bodies_len += init_body_len;
                        }
                    }

                    // Now, `fields_extra_index` points to `bodies`. Let's treat this as one big body.
                    const merged_bodies = zir.bodySlice(fields_extra_index, total_bodies_len);
                    try zir.findTrackableBody(gpa, contents, defers, merged_bodies);
                },

                // Union declarations need tracking and have a body.
                .union_decl => {
                    try contents.explicit_types.append(gpa, inst);

                    const small: Zir.Inst.UnionDecl.Small = @bitCast(extended.small);
                    const extra = zir.extraData(Zir.Inst.UnionDecl, extended.operand);
                    var extra_index = extra.end;
                    extra_index += @intFromBool(small.has_tag_type);
                    const captures_len = if (small.has_captures_len) blk: {
                        const captures_len = zir.extra[extra_index];
                        extra_index += 1;
                        break :blk captures_len;
                    } else 0;
                    const body_len = if (small.has_body_len) blk: {
                        const body_len = zir.extra[extra_index];
                        extra_index += 1;
                        break :blk body_len;
                    } else 0;
                    extra_index += @intFromBool(small.has_fields_len);
                    const decls_len = if (small.has_decls_len) blk: {
                        const decls_len = zir.extra[extra_index];
                        extra_index += 1;
                        break :blk decls_len;
                    } else 0;
                    extra_index += captures_len * 2;
                    extra_index += decls_len;
                    const body = zir.bodySlice(extra_index, body_len);
                    try zir.findTrackableBody(gpa, contents, defers, body);
                },

                // Enum declarations need tracking and have a body.
                .enum_decl => {
                    try contents.explicit_types.append(gpa, inst);

                    const small: Zir.Inst.EnumDecl.Small = @bitCast(extended.small);
                    const extra = zir.extraData(Zir.Inst.EnumDecl, extended.operand);
                    var extra_index = extra.end;
                    extra_index += @intFromBool(small.has_tag_type);
                    const captures_len = if (small.has_captures_len) blk: {
                        const captures_len = zir.extra[extra_index];
                        extra_index += 1;
                        break :blk captures_len;
                    } else 0;
                    const body_len = if (small.has_body_len) blk: {
                        const body_len = zir.extra[extra_index];
                        extra_index += 1;
                        break :blk body_len;
                    } else 0;
                    extra_index += @intFromBool(small.has_fields_len);
                    const decls_len = if (small.has_decls_len) blk: {
                        const decls_len = zir.extra[extra_index];
                        extra_index += 1;
                        break :blk decls_len;
                    } else 0;
                    extra_index += captures_len * 2;
                    extra_index += decls_len;
                    const body = zir.bodySlice(extra_index, body_len);
                    try zir.findTrackableBody(gpa, contents, defers, body);
                },
            }
        },

        // Functions instructions are interesting and have a body.
        .func,
        .func_inferred,
        => {
            const inst_data = datas[@intFromEnum(inst)].pl_node;
            const extra = zir.extraData(Inst.Func, inst_data.payload_index);

            if (extra.data.body_len == 0) {
                // This is just a prototype. No need to track.
                assert(extra.data.ret_ty.body_len < 2);
                return;
            }

            assert(contents.func_decl == null);
            contents.func_decl = inst;

            var extra_index: usize = extra.end;
            switch (extra.data.ret_ty.body_len) {
                0 => {},
                1 => extra_index += 1,
                else => {
                    const body = zir.bodySlice(extra_index, extra.data.ret_ty.body_len);
                    extra_index += body.len;
                    try zir.findTrackableBody(gpa, contents, defers, body);
                },
            }
            const body = zir.bodySlice(extra_index, extra.data.body_len);
            return zir.findTrackableBody(gpa, contents, defers, body);
        },
        .func_fancy => {
            const inst_data = datas[@intFromEnum(inst)].pl_node;
            const extra = zir.extraData(Inst.FuncFancy, inst_data.payload_index);

            if (extra.data.body_len == 0) {
                // This is just a prototype. No need to track.
                assert(!extra.data.bits.has_cc_body);
                assert(!extra.data.bits.has_ret_ty_body);
                return;
            }

            assert(contents.func_decl == null);
            contents.func_decl = inst;

            var extra_index: usize = extra.end;

            if (extra.data.bits.has_cc_body) {
                const body_len = zir.extra[extra_index];
                extra_index += 1;
                const body = zir.bodySlice(extra_index, body_len);
                try zir.findTrackableBody(gpa, contents, defers, body);
                extra_index += body.len;
            } else if (extra.data.bits.has_cc_ref) {
                extra_index += 1;
            }

            if (extra.data.bits.has_ret_ty_body) {
                const body_len = zir.extra[extra_index];
                extra_index += 1;
                const body = zir.bodySlice(extra_index, body_len);
                try zir.findTrackableBody(gpa, contents, defers, body);
                extra_index += body.len;
            } else if (extra.data.bits.has_ret_ty_ref) {
                extra_index += 1;
            }

            extra_index += @intFromBool(extra.data.bits.has_any_noalias);

            const body = zir.bodySlice(extra_index, extra.data.body_len);
            return zir.findTrackableBody(gpa, contents, defers, body);
        },

        // Block instructions, recurse over the bodies.

        .block,
        .block_inline,
        .c_import,
        .typeof_builtin,
        .loop,
        => {
            const inst_data = datas[@intFromEnum(inst)].pl_node;
            const extra = zir.extraData(Inst.Block, inst_data.payload_index);
            const body = zir.bodySlice(extra.end, extra.data.body_len);
            return zir.findTrackableBody(gpa, contents, defers, body);
        },
        .block_comptime => {
            const inst_data = datas[@intFromEnum(inst)].pl_node;
            const extra = zir.extraData(Inst.BlockComptime, inst_data.payload_index);
            const body = zir.bodySlice(extra.end, extra.data.body_len);
            return zir.findTrackableBody(gpa, contents, defers, body);
        },
        .condbr, .condbr_inline => {
            const inst_data = datas[@intFromEnum(inst)].pl_node;
            const extra = zir.extraData(Inst.CondBr, inst_data.payload_index);
            const then_body = zir.bodySlice(extra.end, extra.data.then_body_len);
            const else_body = zir.bodySlice(extra.end + then_body.len, extra.data.else_body_len);
            try zir.findTrackableBody(gpa, contents, defers, then_body);
            try zir.findTrackableBody(gpa, contents, defers, else_body);
        },
        .@"try", .try_ptr => {
            const inst_data = datas[@intFromEnum(inst)].pl_node;
            const extra = zir.extraData(Inst.Try, inst_data.payload_index);
            const body = zir.bodySlice(extra.end, extra.data.body_len);
            try zir.findTrackableBody(gpa, contents, defers, body);
        },
        .switch_block, .switch_block_ref => return zir.findTrackableSwitch(gpa, contents, defers, inst, .normal),
        .switch_block_err_union => return zir.findTrackableSwitch(gpa, contents, defers, inst, .err_union),

        .suspend_block => @panic("TODO iterate suspend block"),

        .param, .param_comptime => {
            const inst_data = datas[@intFromEnum(inst)].pl_tok;
            const extra = zir.extraData(Inst.Param, inst_data.payload_index);
            const body = zir.bodySlice(extra.end, extra.data.type.body_len);
            try zir.findTrackableBody(gpa, contents, defers, body);
        },

        inline .call, .field_call => |tag| {
            const inst_data = datas[@intFromEnum(inst)].pl_node;
            const extra = zir.extraData(switch (tag) {
                .call => Inst.Call,
                .field_call => Inst.FieldCall,
                else => unreachable,
            }, inst_data.payload_index);
            // It's easiest to just combine all the arg bodies into one body, like we do above for `struct_decl`.
            const args_len = extra.data.flags.args_len;
            if (args_len > 0) {
                const first_arg_start_off = args_len;
                const final_arg_end_off = zir.extra[extra.end + args_len - 1];
                const args_body = zir.bodySlice(extra.end + first_arg_start_off, final_arg_end_off - first_arg_start_off);
                try zir.findTrackableBody(gpa, contents, defers, args_body);
            }
        },
        .@"defer" => {
            const inst_data = datas[@intFromEnum(inst)].@"defer";
            const gop = try defers.getOrPut(gpa, inst_data.index);
            if (!gop.found_existing) {
                const body = zir.bodySlice(inst_data.index, inst_data.len);
                try zir.findTrackableBody(gpa, contents, defers, body);
            }
        },
        .defer_err_code => {
            const inst_data = datas[@intFromEnum(inst)].defer_err_code;
            const extra = zir.extraData(Inst.DeferErrCode, inst_data.payload_index).data;
            const gop = try defers.getOrPut(gpa, extra.index);
            if (!gop.found_existing) {
                const body = zir.bodySlice(extra.index, extra.len);
                try zir.findTrackableBody(gpa, contents, defers, body);
            }
        },
    }
}

fn findTrackableSwitch(
    zir: Zir,
    gpa: Allocator,
    contents: *DeclContents,
    defers: *std.AutoHashMapUnmanaged(u32, void),
    inst: Inst.Index,
    /// Distinguishes between `switch_block[_ref]` and `switch_block_err_union`.
    comptime kind: enum { normal, err_union },
) Allocator.Error!void {
    const inst_data = zir.instructions.items(.data)[@intFromEnum(inst)].pl_node;
    const extra = zir.extraData(switch (kind) {
        .normal => Inst.SwitchBlock,
        .err_union => Inst.SwitchBlockErrUnion,
    }, inst_data.payload_index);

    var extra_index: usize = extra.end;

    const multi_cases_len = if (extra.data.bits.has_multi_cases) blk: {
        const multi_cases_len = zir.extra[extra_index];
        extra_index += 1;
        break :blk multi_cases_len;
    } else 0;

    if (switch (kind) {
        .normal => extra.data.bits.any_has_tag_capture,
        .err_union => extra.data.bits.any_uses_err_capture,
    }) {
        extra_index += 1;
    }

    const has_special = switch (kind) {
        .normal => extra.data.bits.specialProng() != .none,
        .err_union => has_special: {
            // Handle `non_err_body` first.
            const prong_info: Inst.SwitchBlock.ProngInfo = @bitCast(zir.extra[extra_index]);
            extra_index += 1;
            const body = zir.bodySlice(extra_index, prong_info.body_len);
            extra_index += body.len;

            try zir.findTrackableBody(gpa, contents, defers, body);

            break :has_special extra.data.bits.has_else;
        },
    };

    if (has_special) {
        const prong_info: Inst.SwitchBlock.ProngInfo = @bitCast(zir.extra[extra_index]);
        extra_index += 1;
        const body = zir.bodySlice(extra_index, prong_info.body_len);
        extra_index += body.len;

        try zir.findTrackableBody(gpa, contents, defers, body);
    }

    {
        const scalar_cases_len = extra.data.bits.scalar_cases_len;
        for (0..scalar_cases_len) |_| {
            extra_index += 1;
            const prong_info: Inst.SwitchBlock.ProngInfo = @bitCast(zir.extra[extra_index]);
            extra_index += 1;
            const body = zir.bodySlice(extra_index, prong_info.body_len);
            extra_index += body.len;

            try zir.findTrackableBody(gpa, contents, defers, body);
        }
    }
    {
        for (0..multi_cases_len) |_| {
            const items_len = zir.extra[extra_index];
            extra_index += 1;
            const ranges_len = zir.extra[extra_index];
            extra_index += 1;
            const prong_info: Inst.SwitchBlock.ProngInfo = @bitCast(zir.extra[extra_index]);
            extra_index += 1;

            extra_index += items_len + ranges_len * 2;

            const body = zir.bodySlice(extra_index, prong_info.body_len);
            extra_index += body.len;

            try zir.findTrackableBody(gpa, contents, defers, body);
        }
    }
}

fn findTrackableBody(
    zir: Zir,
    gpa: Allocator,
    contents: *DeclContents,
    defers: *std.AutoHashMapUnmanaged(u32, void),
    body: []const Inst.Index,
) Allocator.Error!void {
    for (body) |member| {
        try zir.findTrackableInner(gpa, contents, defers, member);
    }
}

pub const FnInfo = struct {
    param_body: []const Inst.Index,
    param_body_inst: Inst.Index,
    ret_ty_body: []const Inst.Index,
    body: []const Inst.Index,
    ret_ty_ref: Zir.Inst.Ref,
    ret_ty_is_generic: bool,
    total_params_len: u32,
    inferred_error_set: bool,
};

pub fn getParamBody(zir: Zir, fn_inst: Inst.Index) []const Zir.Inst.Index {
    const tags = zir.instructions.items(.tag);
    const datas = zir.instructions.items(.data);
    const inst_data = datas[@intFromEnum(fn_inst)].pl_node;

    const param_block_index = switch (tags[@intFromEnum(fn_inst)]) {
        .func, .func_inferred => blk: {
            const extra = zir.extraData(Inst.Func, inst_data.payload_index);
            break :blk extra.data.param_block;
        },
        .func_fancy => blk: {
            const extra = zir.extraData(Inst.FuncFancy, inst_data.payload_index);
            break :blk extra.data.param_block;
        },
        else => unreachable,
    };

    switch (tags[@intFromEnum(param_block_index)]) {
        .block, .block_comptime, .block_inline => {
            const param_block = zir.extraData(Inst.Block, datas[@intFromEnum(param_block_index)].pl_node.payload_index);
            return zir.bodySlice(param_block.end, param_block.data.body_len);
        },
        .declaration => {
            return zir.getDeclaration(param_block_index).value_body.?;
        },
        else => unreachable,
    }
}

pub fn getParamName(zir: Zir, param_inst: Inst.Index) ?NullTerminatedString {
    const inst = zir.instructions.get(@intFromEnum(param_inst));
    return switch (inst.tag) {
        .param, .param_comptime => zir.extraData(Inst.Param, inst.data.pl_tok.payload_index).data.name,
        .param_anytype, .param_anytype_comptime => inst.data.str_tok.start,
        else => null,
    };
}

pub fn getFnInfo(zir: Zir, fn_inst: Inst.Index) FnInfo {
    const tags = zir.instructions.items(.tag);
    const datas = zir.instructions.items(.data);
    const info: struct {
        param_block: Inst.Index,
        body: []const Inst.Index,
        ret_ty_ref: Inst.Ref,
        ret_ty_body: []const Inst.Index,
        ret_ty_is_generic: bool,
        ies: bool,
    } = switch (tags[@intFromEnum(fn_inst)]) {
        .func, .func_inferred => |tag| blk: {
            const inst_data = datas[@intFromEnum(fn_inst)].pl_node;
            const extra = zir.extraData(Inst.Func, inst_data.payload_index);

            var extra_index: usize = extra.end;
            var ret_ty_ref: Inst.Ref = .none;
            var ret_ty_body: []const Inst.Index = &.{};

            switch (extra.data.ret_ty.body_len) {
                0 => {
                    ret_ty_ref = .void_type;
                },
                1 => {
                    ret_ty_ref = @enumFromInt(zir.extra[extra_index]);
                    extra_index += 1;
                },
                else => {
                    ret_ty_body = zir.bodySlice(extra_index, extra.data.ret_ty.body_len);
                    extra_index += ret_ty_body.len;
                },
            }

            const body = zir.bodySlice(extra_index, extra.data.body_len);
            extra_index += body.len;

            break :blk .{
                .param_block = extra.data.param_block,
                .ret_ty_ref = ret_ty_ref,
                .ret_ty_body = ret_ty_body,
                .body = body,
                .ret_ty_is_generic = extra.data.ret_ty.is_generic,
                .ies = tag == .func_inferred,
            };
        },
        .func_fancy => blk: {
            const inst_data = datas[@intFromEnum(fn_inst)].pl_node;
            const extra = zir.extraData(Inst.FuncFancy, inst_data.payload_index);

            var extra_index: usize = extra.end;
            var ret_ty_ref: Inst.Ref = .none;
            var ret_ty_body: []const Inst.Index = &.{};

            if (extra.data.bits.has_cc_body) {
                extra_index += zir.extra[extra_index] + 1;
            } else if (extra.data.bits.has_cc_ref) {
                extra_index += 1;
            }
            if (extra.data.bits.has_ret_ty_body) {
                const body_len = zir.extra[extra_index];
                extra_index += 1;
                ret_ty_body = zir.bodySlice(extra_index, body_len);
                extra_index += ret_ty_body.len;
            } else if (extra.data.bits.has_ret_ty_ref) {
                ret_ty_ref = @enumFromInt(zir.extra[extra_index]);
                extra_index += 1;
            } else {
                ret_ty_ref = .void_type;
            }

            extra_index += @intFromBool(extra.data.bits.has_any_noalias);

            const body = zir.bodySlice(extra_index, extra.data.body_len);
            extra_index += body.len;
            break :blk .{
                .param_block = extra.data.param_block,
                .ret_ty_ref = ret_ty_ref,
                .ret_ty_body = ret_ty_body,
                .body = body,
                .ret_ty_is_generic = extra.data.bits.ret_ty_is_generic,
                .ies = extra.data.bits.is_inferred_error,
            };
        },
        else => unreachable,
    };
    const param_body = zir.getParamBody(fn_inst);
    var total_params_len: u32 = 0;
    for (param_body) |inst| {
        switch (tags[@intFromEnum(inst)]) {
            .param, .param_comptime, .param_anytype, .param_anytype_comptime => {
                total_params_len += 1;
            },
            else => continue,
        }
    }
    return .{
        .param_body = param_body,
        .param_body_inst = info.param_block,
        .ret_ty_body = info.ret_ty_body,
        .ret_ty_ref = info.ret_ty_ref,
        .body = info.body,
        .total_params_len = total_params_len,
        .ret_ty_is_generic = info.ret_ty_is_generic,
        .inferred_error_set = info.ies,
    };
}

pub fn getDeclaration(zir: Zir, inst: Zir.Inst.Index) Inst.Declaration.Unwrapped {
    assert(zir.instructions.items(.tag)[@intFromEnum(inst)] == .declaration);
    const pl_node = zir.instructions.items(.data)[@intFromEnum(inst)].declaration;
    const extra = zir.extraData(Inst.Declaration, pl_node.payload_index);

    const flags_vals: [2]u32 = .{ extra.data.flags_0, extra.data.flags_1 };
    const flags: Inst.Declaration.Flags = @bitCast(flags_vals);

    var extra_index = extra.end;

    const name: NullTerminatedString = if (flags.id.hasName()) name: {
        const name = zir.extra[extra_index];
        extra_index += 1;
        break :name @enumFromInt(name);
    } else .empty;

    const lib_name: NullTerminatedString = if (flags.id.hasLibName()) lib_name: {
        const lib_name = zir.extra[extra_index];
        extra_index += 1;
        break :lib_name @enumFromInt(lib_name);
    } else .empty;

    const type_body_len: u32 = if (flags.id.hasTypeBody()) len: {
        const len = zir.extra[extra_index];
        extra_index += 1;
        break :len len;
    } else 0;
    const align_body_len: u32, const linksection_body_len: u32, const addrspace_body_len: u32 = lens: {
        if (!flags.id.hasSpecialBodies()) break :lens .{ 0, 0, 0 };
        const lens = zir.extra[extra_index..][0..3].*;
        extra_index += 3;
        break :lens lens;
    };
    const value_body_len: u32 = if (flags.id.hasValueBody()) len: {
        const len = zir.extra[extra_index];
        extra_index += 1;
        break :len len;
    } else 0;

    const type_body = zir.bodySlice(extra_index, type_body_len);
    extra_index += type_body_len;
    const align_body = zir.bodySlice(extra_index, align_body_len);
    extra_index += align_body_len;
    const linksection_body = zir.bodySlice(extra_index, linksection_body_len);
    extra_index += linksection_body_len;
    const addrspace_body = zir.bodySlice(extra_index, addrspace_body_len);
    extra_index += addrspace_body_len;
    const value_body = zir.bodySlice(extra_index, value_body_len);
    extra_index += value_body_len;

    return .{
        .src_node = pl_node.src_node,

        .src_line = flags.src_line,
        .src_column = flags.src_column,

        .kind = flags.id.kind(),
        .name = name,
        .is_pub = flags.id.isPub(),
        .is_threadlocal = flags.id.isThreadlocal(),
        .linkage = flags.id.linkage(),
        .lib_name = lib_name,

        .type_body = if (type_body_len == 0) null else type_body,
        .align_body = if (align_body_len == 0) null else align_body,
        .linksection_body = if (linksection_body_len == 0) null else linksection_body,
        .addrspace_body = if (addrspace_body_len == 0) null else addrspace_body,
        .value_body = if (value_body_len == 0) null else value_body,
    };
}

pub fn getAssociatedSrcHash(zir: Zir, inst: Zir.Inst.Index) ?std.zig.SrcHash {
    const tag = zir.instructions.items(.tag);
    const data = zir.instructions.items(.data);
    switch (tag[@intFromEnum(inst)]) {
        .declaration => {
            const declaration = data[@intFromEnum(inst)].declaration;
            const extra = zir.extraData(Inst.Declaration, declaration.payload_index);
            return @bitCast([4]u32{
                extra.data.src_hash_0,
                extra.data.src_hash_1,
                extra.data.src_hash_2,
                extra.data.src_hash_3,
            });
        },
        .func, .func_inferred => {
            const pl_node = data[@intFromEnum(inst)].pl_node;
            const extra = zir.extraData(Inst.Func, pl_node.payload_index);
            if (extra.data.body_len == 0) {
                // Function type or extern fn - no associated hash
                return null;
            }
            const extra_index = extra.end +
                extra.data.ret_ty.body_len +
                extra.data.body_len +
                @typeInfo(Inst.Func.SrcLocs).@"struct".fields.len;
            return @bitCast([4]u32{
                zir.extra[extra_index + 0],
                zir.extra[extra_index + 1],
                zir.extra[extra_index + 2],
                zir.extra[extra_index + 3],
            });
        },
        .func_fancy => {
            const pl_node = data[@intFromEnum(inst)].pl_node;
            const extra = zir.extraData(Inst.FuncFancy, pl_node.payload_index);
            if (extra.data.body_len == 0) {
                // Function type or extern fn - no associated hash
                return null;
            }
            const bits = extra.data.bits;
            var extra_index = extra.end;
            if (bits.has_cc_body) {
                const body_len = zir.extra[extra_index];
                extra_index += 1 + body_len;
            } else extra_index += @intFromBool(bits.has_cc_ref);
            if (bits.has_ret_ty_body) {
                const body_len = zir.extra[extra_index];
                extra_index += 1 + body_len;
            } else extra_index += @intFromBool(bits.has_ret_ty_ref);
            extra_index += @intFromBool(bits.has_any_noalias);
            extra_index += extra.data.body_len;
            extra_index += @typeInfo(Zir.Inst.Func.SrcLocs).@"struct".fields.len;
            return @bitCast([4]u32{
                zir.extra[extra_index + 0],
                zir.extra[extra_index + 1],
                zir.extra[extra_index + 2],
                zir.extra[extra_index + 3],
            });
        },
        .extended => {},
        else => return null,
    }
    const extended = data[@intFromEnum(inst)].extended;
    switch (extended.opcode) {
        .struct_decl => {
            const extra = zir.extraData(Inst.StructDecl, extended.operand).data;
            return @bitCast([4]u32{
                extra.fields_hash_0,
                extra.fields_hash_1,
                extra.fields_hash_2,
                extra.fields_hash_3,
            });
        },
        .union_decl => {
            const extra = zir.extraData(Inst.UnionDecl, extended.operand).data;
            return @bitCast([4]u32{
                extra.fields_hash_0,
                extra.fields_hash_1,
                extra.fields_hash_2,
                extra.fields_hash_3,
            });
        },
        .enum_decl => {
            const extra = zir.extraData(Inst.EnumDecl, extended.operand).data;
            return @bitCast([4]u32{
                extra.fields_hash_0,
                extra.fields_hash_1,
                extra.fields_hash_2,
                extra.fields_hash_3,
            });
        },
        else => return null,
    }
}

/// When the ZIR update tracking logic must be modified to consider new instructions,
/// change this constant to trigger compile errors at all relevant locations.
pub const inst_tracking_version = 0;

/// Asserts that a ZIR instruction is tracked across incremental updates, and
/// thus may be given an `InternPool.TrackedInst`.
pub fn assertTrackable(zir: Zir, inst_idx: Zir.Inst.Index) void {
    comptime assert(Zir.inst_tracking_version == 0);
    const inst = zir.instructions.get(@intFromEnum(inst_idx));
    switch (inst.tag) {
        .struct_init,
        .struct_init_ref,
        .struct_init_anon,
        => {}, // tracked in order, as the owner instructions of anonymous struct types
        .func, .func_inferred => {
            // These are tracked provided they are actual function declarations, not just bodies.
            const extra = zir.extraData(Inst.Func, inst.data.pl_node.payload_index);
            assert(extra.data.body_len != 0);
        },
        .func_fancy => {
            // These are tracked provided they are actual function declarations, not just bodies.
            const extra = zir.extraData(Inst.FuncFancy, inst.data.pl_node.payload_index);
            assert(extra.data.body_len != 0);
        },
        .declaration => {}, // tracked by correlating names in the namespace of the parent container
        .extended => switch (inst.data.extended.opcode) {
            .struct_decl,
            .union_decl,
            .enum_decl,
            .opaque_decl,
            .reify,
            => {}, // tracked in order, as the owner instructions of explicit container types
            else => unreachable, // assertion failure; not trackable
        },
        else => unreachable, // assertion failure; not trackable
    }
}

pub fn typeCapturesLen(zir: Zir, type_decl: Inst.Index) u32 {
    const inst = zir.instructions.get(@intFromEnum(type_decl));
    assert(inst.tag == .extended);
    switch (inst.data.extended.opcode) {
        .struct_decl => {
            const small: Inst.StructDecl.Small = @bitCast(inst.data.extended.small);
            if (!small.has_captures_len) return 0;
            const extra = zir.extraData(Inst.StructDecl, inst.data.extended.operand);
            return zir.extra[extra.end];
        },
        .union_decl => {
            const small: Inst.UnionDecl.Small = @bitCast(inst.data.extended.small);
            if (!small.has_captures_len) return 0;
            const extra = zir.extraData(Inst.UnionDecl, inst.data.extended.operand);
            return zir.extra[extra.end + @intFromBool(small.has_tag_type)];
        },
        .enum_decl => {
            const small: Inst.EnumDecl.Small = @bitCast(inst.data.extended.small);
            if (!small.has_captures_len) return 0;
            const extra = zir.extraData(Inst.EnumDecl, inst.data.extended.operand);
            return zir.extra[extra.end + @intFromBool(small.has_tag_type)];
        },
        .opaque_decl => {
            const small: Inst.OpaqueDecl.Small = @bitCast(inst.data.extended.small);
            if (!small.has_captures_len) return 0;
            const extra = zir.extraData(Inst.OpaqueDecl, inst.data.extended.operand);
            return zir.extra[extra.end];
        },
        else => unreachable,
    }
}
