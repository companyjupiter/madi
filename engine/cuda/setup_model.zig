// setup_model.zig — safetensors → quarks 폴더 변환 (Zig 단독, Python 불필요)
// Usage: sovereign_whisper_setup.exe model.safetensors
const std = @import("std");

pub fn main() !void {
    const alloc = std.heap.page_allocator;
    const out = std.io.getStdOut().writer();

    // Get safetensors path from args
    var args = try std.process.argsAlloc(alloc);
    if (args.len < 2) {
        try out.print("Usage: sovereign_whisper_setup.exe model.safetensors\n", .{});
        try out.print("\nDownload model.safetensors from:\n  https://huggingface.co/openai/whisper-large-v3-turbo\n", .{});
        return;
    }
    const sf_path = args[1];
    try out.print("=== Madi Model Setup ===\n", .{});
    try out.print("Loading: {s}\n", .{sf_path});

    // Read entire safetensors file
    const f = try std.fs.cwd().openFile(sf_path, .{});
    defer f.close();
    const file_size = try f.getEndPos();
    try out.print("File size: {d} MB\n", .{file_size / (1024*1024)});

    const data = try alloc.alloc(u8, file_size);
    const read_n = try f.readAll(data);
    if (read_n != file_size) return error.IncompleteRead;

    // Parse safetensors header
    const header_size = std.mem.readInt(u64, data[0..8], .little);
    const header_json = data[8..8+header_size];
    const tensor_data_start = 8 + header_size;
    try out.print("Header: {d} bytes, Data start: {d}\n", .{header_size, tensor_data_start});

    // Mapping: safetensors key → quarks path
    // HuggingFace format → our atom format
    const base = "quarks/whisper-turbo-v3-atom";

    // Parse JSON to extract tensor entries
    // Format: "key": {"dtype": "F16", "shape": [...], "data_offsets": [start, end]}
    var count: u32 = 0;
    var pos: usize = 0;
    while (pos < header_json.len) {
        // Find next tensor key
        const key_start = std.mem.indexOfPos(u8, header_json, pos, "\"") orelse break;
        const key_end = std.mem.indexOfPos(u8, header_json, key_start + 1, "\"") orelse break;
        const key = header_json[key_start+1..key_end];

        // Skip __metadata__
        if (std.mem.eql(u8, key, "__metadata__")) {
            pos = key_end + 1;
            // Skip to next closing brace
            if (std.mem.indexOfPos(u8, header_json, pos, "}")) |p| { pos = p + 1; }
            continue;
        }

        // Find data_offsets
        const offsets_str = "data_offsets";
        const off_pos = std.mem.indexOfPos(u8, header_json, key_end, offsets_str) orelse { pos = key_end + 1; continue; };
        const bracket_start = std.mem.indexOfPos(u8, header_json, off_pos, "[") orelse { pos = key_end + 1; continue; };
        const comma = std.mem.indexOfPos(u8, header_json, bracket_start, ",") orelse { pos = key_end + 1; continue; };
        const bracket_end = std.mem.indexOfPos(u8, header_json, comma, "]") orelse { pos = key_end + 1; continue; };

        const start_str = std.mem.trim(u8, header_json[bracket_start+1..comma], " ");
        const end_str = std.mem.trim(u8, header_json[comma+1..bracket_end], " ");

        const data_start = std.fmt.parseInt(u64, start_str, 10) catch { pos = bracket_end + 1; continue; };
        const data_end = std.fmt.parseInt(u64, end_str, 10) catch { pos = bracket_end + 1; continue; };
        const tensor_bytes = data[tensor_data_start + data_start .. tensor_data_start + data_end];

        // Convert key to quarks path
        var path_buf: [512]u8 = undefined;
        const quarks_path = safetensorsKeyToQuarksPath(key, &path_buf, base) orelse {
            pos = bracket_end + 1;
            continue;
        };

        // Create directory and write data.bin
        const dir_end = std.mem.lastIndexOf(u8, quarks_path, "/") orelse { pos = bracket_end + 1; continue; };
        const dir_path = quarks_path[0..dir_end];
        std.fs.cwd().makePath(dir_path) catch {};

        const wf = std.fs.cwd().createFile(quarks_path, .{}) catch { pos = bracket_end + 1; continue; };
        defer wf.close();
        wf.writeAll(tensor_bytes) catch { pos = bracket_end + 1; continue; };

        count += 1;
        pos = bracket_end + 1;
    }
    try out.print("\n=== {d} tensors extracted ===\n", .{count});

    // Generate pos_emb_f32.bin (convert F16 → F32)
    try generatePosEmbF32(alloc, data, header_json, tensor_data_start, base, out);

    // Generate tok_emb_f32.bin
    try generateTokEmbF32(alloc, data, header_json, tensor_data_start, base, out);

    // Generate enc_weights/pos_emb.bin
    try generateEncPosEmb(alloc, data, header_json, tensor_data_start, base, out);

    try out.print("\n=== Setup complete! ===\n", .{});
    try out.print("Model ready at: {s}/\n", .{base});
    try out.print("Run: sovereign_whisper.exe audio.wav\n", .{});
}

fn safetensorsKeyToQuarksPath(key: []const u8, buf: *[512]u8, base: []const u8) ?[]const u8 {
    // model.decoder.layers.N.self_attn.q_proj.weight → decoder/blocks/N/attn/query/weight/data.bin
    // model.decoder.layers.N.self_attn.k_proj.weight → decoder/blocks/N/attn/key/weight/data.bin
    // model.decoder.layers.N.self_attn.v_proj.weight → decoder/blocks/N/attn/value/weight/data.bin
    // model.decoder.layers.N.self_attn.out_proj.weight → decoder/blocks/N/attn/out/weight/data.bin
    // model.decoder.layers.N.self_attn_layer_norm.weight → decoder/blocks/N/attn_ln/weight/data.bin
    // model.decoder.layers.N.encoder_attn.q_proj.weight → decoder/blocks/N/cross_attn/query/weight/data.bin
    // model.decoder.layers.N.encoder_attn.k_proj.weight → decoder/blocks/N/cross_attn/key/weight/data.bin
    // model.decoder.layers.N.encoder_attn.v_proj.weight → decoder/blocks/N/cross_attn/value/weight/data.bin
    // model.decoder.layers.N.encoder_attn.out_proj.weight → decoder/blocks/N/cross_attn/out/weight/data.bin
    // model.decoder.layers.N.encoder_attn_layer_norm.weight → decoder/blocks/N/cross_attn_ln/weight/data.bin
    // model.decoder.layers.N.fc1.weight → decoder/blocks/N/mlp/0/weight/data.bin
    // model.decoder.layers.N.fc2.weight → decoder/blocks/N/mlp/2/weight/data.bin
    // model.decoder.layers.N.final_layer_norm.weight → decoder/blocks/N/mlp_ln/weight/data.bin
    // model.decoder.layer_norm.weight → decoder/ln/weight/data.bin
    // model.encoder.layers.N.self_attn.q_proj.weight → encoder/blocks/N/attn/query/weight/data.bin
    // model.encoder.layers.N.self_attn_layer_norm.weight → encoder/blocks/N/attn_ln/weight/data.bin
    // model.encoder.layers.N.fc1.weight → encoder/blocks/N/mlp/0/weight/data.bin
    // model.encoder.layers.N.fc2.weight → encoder/blocks/N/mlp/2/weight/data.bin
    // model.encoder.layers.N.final_layer_norm.weight → encoder/blocks/N/mlp_ln/weight/data.bin
    // model.encoder.layer_norm.weight → encoder/ln_post/weight/data.bin

    // Skip proj_out (duplicate of token embedding, transposed)
    if (std.mem.indexOf(u8, key, "proj_out") != null) return null;

    // Decoder layers
    if (std.mem.startsWith(u8, key, "model.decoder.layers.")) {
        const rest = key["model.decoder.layers.".len..];
        const dot = std.mem.indexOf(u8, rest, ".") orelse return null;
        const layer_num = rest[0..dot];
        const suffix = rest[dot+1..];
        return mapLayerPath(buf, base, "decoder", layer_num, suffix);
    }
    // Encoder layers
    if (std.mem.startsWith(u8, key, "model.encoder.layers.")) {
        const rest = key["model.encoder.layers.".len..];
        const dot = std.mem.indexOf(u8, rest, ".") orelse return null;
        const layer_num = rest[0..dot];
        const suffix = rest[dot+1..];
        return mapLayerPath(buf, base, "encoder", layer_num, suffix);
    }
    // Decoder layer norm
    if (std.mem.eql(u8, key, "model.decoder.layer_norm.weight"))
        return std.fmt.bufPrint(buf, "{s}/decoder/ln/weight/data.bin", .{base}) catch null;
    if (std.mem.eql(u8, key, "model.decoder.layer_norm.bias"))
        return std.fmt.bufPrint(buf, "{s}/decoder/ln/bias/data.bin", .{base}) catch null;
    // Encoder layer norm
    if (std.mem.eql(u8, key, "model.encoder.layer_norm.weight"))
        return std.fmt.bufPrint(buf, "{s}/encoder/ln_post/weight/data.bin", .{base}) catch null;
    if (std.mem.eql(u8, key, "model.encoder.layer_norm.bias"))
        return std.fmt.bufPrint(buf, "{s}/encoder/ln_post/bias/data.bin", .{base}) catch null;
    // Decoder embed tokens
    if (std.mem.eql(u8, key, "model.decoder.embed_tokens.weight"))
        return std.fmt.bufPrint(buf, "{s}/decoder/token_embedding/weight/data.bin", .{base}) catch null;
    // Encoder conv1/conv2
    if (std.mem.eql(u8, key, "model.encoder.conv1.weight"))
        return std.fmt.bufPrint(buf, "{s}/enc_weights/conv1_weight/data.bin", .{base}) catch null;
    if (std.mem.eql(u8, key, "model.encoder.conv1.bias"))
        return std.fmt.bufPrint(buf, "{s}/enc_weights/conv1_bias/data.bin", .{base}) catch null;
    if (std.mem.eql(u8, key, "model.encoder.conv2.weight"))
        return std.fmt.bufPrint(buf, "{s}/enc_weights/conv2_weight/data.bin", .{base}) catch null;
    if (std.mem.eql(u8, key, "model.encoder.conv2.bias"))
        return std.fmt.bufPrint(buf, "{s}/enc_weights/conv2_bias/data.bin", .{base}) catch null;
    // Encoder embed positions
    if (std.mem.eql(u8, key, "model.encoder.embed_positions.weight"))
        return std.fmt.bufPrint(buf, "{s}/enc_weights/pos_emb_raw/data.bin", .{base}) catch null;
    // Decoder embed positions
    if (std.mem.eql(u8, key, "model.decoder.embed_positions.weight"))
        return std.fmt.bufPrint(buf, "{s}/decoder/pos_emb_raw/data.bin", .{base}) catch null;

    return null;
}

fn mapLayerPath(buf: *[512]u8, base: []const u8, enc_dec: []const u8, layer_num: []const u8, suffix: []const u8) ?[]const u8 {
    // self_attn.q_proj.weight → attn/query/weight
    if (std.mem.startsWith(u8, suffix, "self_attn.q_proj."))
        return fmtLP(buf, base, enc_dec, layer_num, "attn/query", suffix[17..]);
    if (std.mem.startsWith(u8, suffix, "self_attn.k_proj."))
        return fmtLP(buf, base, enc_dec, layer_num, "attn/key", suffix[17..]);
    if (std.mem.startsWith(u8, suffix, "self_attn.v_proj."))
        return fmtLP(buf, base, enc_dec, layer_num, "attn/value", suffix[17..]);
    if (std.mem.startsWith(u8, suffix, "self_attn.out_proj."))
        return fmtLP(buf, base, enc_dec, layer_num, "attn/out", suffix[19..]);
    if (std.mem.startsWith(u8, suffix, "self_attn_layer_norm."))
        return fmtLP(buf, base, enc_dec, layer_num, "attn_ln", suffix[21..]);
    // encoder_attn (cross attention, decoder only)
    if (std.mem.startsWith(u8, suffix, "encoder_attn.q_proj."))
        return fmtLP(buf, base, enc_dec, layer_num, "cross_attn/query", suffix[20..]);
    if (std.mem.startsWith(u8, suffix, "encoder_attn.k_proj."))
        return fmtLP(buf, base, enc_dec, layer_num, "cross_attn/key", suffix[20..]);
    if (std.mem.startsWith(u8, suffix, "encoder_attn.v_proj."))
        return fmtLP(buf, base, enc_dec, layer_num, "cross_attn/value", suffix[20..]);
    if (std.mem.startsWith(u8, suffix, "encoder_attn.out_proj."))
        return fmtLP(buf, base, enc_dec, layer_num, "cross_attn/out", suffix[22..]);
    if (std.mem.startsWith(u8, suffix, "encoder_attn_layer_norm."))
        return fmtLP(buf, base, enc_dec, layer_num, "cross_attn_ln", suffix[24..]);
    // MLP
    if (std.mem.startsWith(u8, suffix, "fc1."))
        return fmtLP(buf, base, enc_dec, layer_num, "mlp/0", suffix[4..]);
    if (std.mem.startsWith(u8, suffix, "fc2."))
        return fmtLP(buf, base, enc_dec, layer_num, "mlp/2", suffix[4..]);
    if (std.mem.startsWith(u8, suffix, "final_layer_norm."))
        return fmtLP(buf, base, enc_dec, layer_num, "mlp_ln", suffix[17..]);
    return null;
}

fn fmtLP(buf: *[512]u8, base: []const u8, enc_dec: []const u8, layer: []const u8, component: []const u8, wb: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}/{s}/blocks/{s}/{s}/{s}/data.bin", .{base, enc_dec, layer, component, wb}) catch null;
}

fn findTensorData(header_json: []const u8, tensor_data_start: u64, all_data: []const u8, key_name: []const u8) ?[]const u8 {
    const key_pos = std.mem.indexOf(u8, header_json, key_name) orelse return null;
    const offsets_str = "data_offsets";
    const off_pos = std.mem.indexOfPos(u8, header_json, key_pos, offsets_str) orelse return null;
    const bracket_start = std.mem.indexOfPos(u8, header_json, off_pos, "[") orelse return null;
    const comma = std.mem.indexOfPos(u8, header_json, bracket_start, ",") orelse return null;
    const bracket_end = std.mem.indexOfPos(u8, header_json, comma, "]") orelse return null;

    const start_str = std.mem.trim(u8, header_json[bracket_start+1..comma], " ");
    const end_str = std.mem.trim(u8, header_json[comma+1..bracket_end], " ");

    const ds = std.fmt.parseInt(u64, start_str, 10) catch return null;
    const de = std.fmt.parseInt(u64, end_str, 10) catch return null;

    return all_data[tensor_data_start + ds .. tensor_data_start + de];
}

fn generatePosEmbF32(alloc: std.mem.Allocator, data: []const u8, header_json: []const u8, tensor_data_start: u64, base: []const u8, out: anytype) !void {
    const raw = findTensorData(header_json, tensor_data_start, data, "model.decoder.embed_positions.weight") orelse return;
    const n = raw.len / 2;
    var f32_buf = try alloc.alloc(f32, n);
    defer alloc.free(f32_buf);
    const u16s = @as([*]const u16, @ptrCast(@alignCast(raw.ptr)))[0..n];
    for (0..n) |i| { f32_buf[i] = @floatCast(@as(f16, @bitCast(u16s[i]))); }

    var pb: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&pb, "{s}/pos_emb_f32.bin", .{base}) catch return;
    const wf = try std.fs.cwd().createFile(path, .{});
    defer wf.close();
    try wf.writeAll(std.mem.sliceAsBytes(f32_buf));
    try out.print("Generated pos_emb_f32.bin ({d} floats)\n", .{n});
}

fn generateTokEmbF32(alloc: std.mem.Allocator, data: []const u8, header_json: []const u8, tensor_data_start: u64, base: []const u8, out: anytype) !void {
    const raw = findTensorData(header_json, tensor_data_start, data, "model.decoder.embed_tokens.weight") orelse return;
    const n = raw.len / 2;
    var f32_buf = try alloc.alloc(f32, n);
    defer alloc.free(f32_buf);
    const u16s = @as([*]const u16, @ptrCast(@alignCast(raw.ptr)))[0..n];
    for (0..n) |i| { f32_buf[i] = @floatCast(@as(f16, @bitCast(u16s[i]))); }

    var pb: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&pb, "{s}/tok_emb_f32.bin", .{base}) catch return;
    const wf = try std.fs.cwd().createFile(path, .{});
    defer wf.close();
    try wf.writeAll(std.mem.sliceAsBytes(f32_buf));
    try out.print("Generated tok_emb_f32.bin ({d} floats)\n", .{n});
}

fn generateEncPosEmb(alloc: std.mem.Allocator, data: []const u8, header_json: []const u8, tensor_data_start: u64, base: []const u8, out: anytype) !void {
    const raw = findTensorData(header_json, tensor_data_start, data, "model.encoder.embed_positions.weight") orelse return;
    var pb: [256]u8 = undefined;
    _ = alloc;
    const dir_path = std.fmt.bufPrint(&pb, "{s}/enc_weights", .{base}) catch return;
    std.fs.cwd().makePath(dir_path) catch {};
    var pb2: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&pb2, "{s}/enc_weights/pos_emb.bin", .{base}) catch return;
    const wf = try std.fs.cwd().createFile(path, .{});
    defer wf.close();
    try wf.writeAll(raw);
    try out.print("Generated enc_weights/pos_emb.bin ({d} bytes)\n", .{raw.len});
}
