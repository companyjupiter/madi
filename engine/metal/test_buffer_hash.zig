const std = @import("std");

extern fn mtl_test_buffer_hash_delete_chain() c_int;

pub fn main() !void {
    const rc = mtl_test_buffer_hash_delete_chain();
    if (rc != 0) return error.BufferHashDeleteChainBroken;
    try std.io.getStdOut().writer().print("PASS buffer hash delete-chain\n", .{});
}
