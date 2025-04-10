package mem0

import "base:intrinsics"
import "base:runtime"
import "core:mem"
import "core:mem/virtual"

Allocator       :: runtime.Allocator
Allocator_Error :: runtime.Allocator_Error
Arena           :: virtual.Arena
Arena_Temp      :: virtual.Arena_Temp

KIB :: 1 << 10
MIB :: 1 << 20
GIB :: 1 << 30

@(thread_local, private)
scratches: [2]Arena

@(init)
init_scratches_on_thread :: proc()
{
	init_arena_growing(&scratches[0])
	init_arena_growing(&scratches[1])
}

copy :: #force_inline proc "contextless" (dst, src: rawptr, len: int) -> rawptr
{
	intrinsics.mem_copy(dst, src, len)
	return dst
}

set :: #force_inline proc "contextless" (data: rawptr, value: byte, len: int) -> rawptr
{
	return runtime.memset(data, i32(value), len)
}

zero :: #force_inline proc "contextless" (data: rawptr, len: int) -> rawptr
{
	intrinsics.mem_zero(data, len)
	return data
}

to_bytes :: #force_inline proc "contextless" (val: any) -> []byte
{
	return mem.any_to_bytes(val)
}

a :: #force_inline proc "contextless" (arena: ^Arena) -> Allocator
{
	return Allocator{
		procedure = virtual.arena_allocator_proc,
		data = arena,
	}
}

init_arena_buffer :: #force_inline proc(arena: ^Arena, buffer: []byte) -> Allocator_Error
{
	return virtual.arena_init_buffer(arena, buffer)
}

init_arena_growing :: proc(
	arena: ^Arena, 
	reserved := virtual.DEFAULT_ARENA_GROWING_MINIMUM_BLOCK_SIZE
) -> Allocator_Error
{
	return virtual.arena_init_growing(arena, uint(reserved))
}

init_arena_static :: proc(
	arena: ^Arena, 
	reserved := virtual.DEFAULT_ARENA_STATIC_RESERVE_SIZE,
	committed := virtual.DEFAULT_ARENA_STATIC_COMMIT_SIZE
) -> Allocator_Error
{
	return virtual.arena_init_static(arena, uint(reserved), uint(committed))
}

clear_arena :: #force_inline proc(arena: ^Arena)
{
	free_all(a(arena))
}

destroy_arena :: #force_inline proc(arena: ^Arena)
{
	virtual.arena_destroy(arena)
}

begin_scratch :: #force_inline proc(conflict: ^Arena = nil) -> Arena_Temp
{
	return virtual.arena_temp_begin(get_scratch(conflict))
}

@(deferred_out=end_scratch)
scope_scratch :: #force_inline proc(conflict: ^Arena = nil) -> Arena_Temp
{
	return begin_scratch(get_scratch(conflict))
}

end_scratch :: #force_inline proc(temp: Arena_Temp)
{
	virtual.arena_temp_end(temp)
}

begin_temp :: #force_inline proc(arena: ^Arena) -> Arena_Temp
{
	return virtual.arena_temp_begin(arena)
}

// @(deferred_out=end_temp)
// scope_temp :: #force_inline proc(arena: ^Arena) -> Arena_Temp
// {
// 	return begin_temp(arena)
// }

end_temp :: #force_inline proc(temp: Arena_Temp)
{
	virtual.arena_temp_end(temp)
}

get_scratch :: #force_inline proc(conflict: ^Arena = nil) -> ^Arena
{
	collision := conflict != nil && scratches[0].curr_block.base == conflict.curr_block.base
	return collision ? &scratches[1] : &scratches[0]
}

get_default_allocator :: #force_inline proc() -> Allocator
{
	return runtime.default_allocator()
}
