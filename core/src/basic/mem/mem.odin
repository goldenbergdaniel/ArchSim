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
init_scratches :: proc()
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

compare :: proc
{
	compare_ptrs,
	compare_slices,
}

compare_ptrs :: #force_inline proc(a, b: rawptr, n: int) -> int
{
	return mem.compare_ptrs(a, b, n)
}

compare_slices :: #force_inline proc(a, b: []byte) -> int
{
	return mem.compare(a, b)
}

to_allocator :: #force_inline proc "contextless" (arena: ^Arena) -> Allocator
{
	return Allocator{
		procedure = virtual.arena_allocator_proc,
		data = arena
	}
}

init_arena_buffer :: proc(arena: ^Arena, buffer: []byte) -> Allocator_Error
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
	free_all(to_allocator(arena))
}

destroy_arena :: #force_inline proc(arena: ^Arena)
{
	virtual.arena_destroy(arena)
}

begin_temp :: #force_inline proc(arena: ^Arena) -> Arena_Temp
{
	return virtual.arena_temp_begin(arena)
}

end_temp :: #force_inline proc(temp: Arena_Temp)
{
	virtual.arena_temp_end(temp)
}

get_scratch :: proc(conflict: ^Arena = nil) -> ^Arena
{
	result := &scratches[0]

	if conflict == nil do return result

	if cast(uintptr) result.curr_block.base == cast(uintptr) conflict.curr_block.base
	{
		result = &scratches[1]
	}

	return result
}

get_default_allocator :: #force_inline proc() -> Allocator
{
	return runtime.default_allocator()
}

get_panic_allocator :: #force_inline proc() -> Allocator
{
	return runtime.panic_allocator()
}
