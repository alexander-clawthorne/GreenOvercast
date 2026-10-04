const std = @import("std");
const settings = @import("persistent_settings.zig");

// Second line of every generated script; only files carrying it are ever replaced or removed.
pub const marker = "# GreenOvercast game shortcut";
pub const name_capacity = 64;

pub const Service = enum {
    xbox,
    geforce_now,

    fn value(self: Service) []const u8 {
        return switch (self) {
            .xbox => "xbox",
            .geforce_now => "geforce-now",
        };
    }
};

pub const Shortcut = struct {
    /// Absolute path of the GreenOvercast port launcher the shortcut runs.
    launcher: []const u8,
    service: Service,
    product_id: []const u8,
};

pub const State = enum {
    absent,
    shortcut,
    foreign,
};

/// Turns a catalog title into a file name every CFW frontend accepts: printable ASCII
/// without path, quoting or wildcard characters, single spaces, no leading or trailing
/// spaces or dots.
pub fn portName(buffer: *[name_capacity]u8, title: []const u8) []const u8 {
    var length: usize = 0;
    var pending_space = false;
    for (title) |byte| {
        const keep = std.ascii.isAlphanumeric(byte) or switch (byte) {
            '-', '_', '.', ',', '!', '&', '(', ')', '+', '\'' => true,
            else => false,
        };
        if (!keep) {
            if (byte == ' ' or byte == ':' or byte == '/' or byte == '\t') pending_space = length > 0;
            continue;
        }
        if (pending_space) {
            if (length + 1 >= buffer.len) break;
            buffer[length] = ' ';
            length += 1;
            pending_space = false;
        }
        if (length == buffer.len) break;
        buffer[length] = byte;
        length += 1;
    }
    while (length > 0 and (buffer[length - 1] == ' ' or buffer[length - 1] == '.')) length -= 1;
    var start: usize = 0;
    while (start < length and (buffer[start] == '.' or buffer[start] == ' ')) start += 1;
    return buffer[start..length];
}

pub fn writeScript(writer: anytype, shortcut: Shortcut, name: []const u8) !void {
    if (!std.fs.path.isAbsolute(shortcut.launcher) or
        std.mem.indexOfAny(u8, shortcut.launcher, "'\n\r") != null) return error.InvalidLauncher;
    if (!settings.validProductId(shortcut.product_id)) return error.InvalidProductId;
    if (name.len == 0 or std.mem.indexOfAny(u8, name, "\n\r") != null) return error.InvalidName;
    try writer.writeAll("#!/bin/bash\n" ++ marker ++ "\n");
    try writer.print("# {s}\n", .{name});
    try writer.print("export GREENOVERCAST_SERVICE={s}\n", .{shortcut.service.value()});
    try writer.writeAll("export GREENOVERCAST_AUTOSTART=1\n");
    // exec keeps $0 as the real launcher, which PortMaster's control.txt resolves GAMEDIR from.
    try writer.print("exec /bin/bash '{s}' '{s}'\n", .{ shortcut.launcher, shortcut.product_id });
}

pub fn state(directory: std.fs.Dir, script_name: []const u8) State {
    const file = directory.openFile(script_name, .{}) catch |err| return switch (err) {
        error.FileNotFound => .absent,
        else => .foreign,
    };
    defer file.close();
    var buffer: [96]u8 = undefined;
    const length = file.readAll(&buffer) catch return .foreign;
    var lines = std.mem.splitScalar(u8, buffer[0..length], '\n');
    _ = lines.next();
    const second = lines.next() orelse return .foreign;
    return if (std.mem.eql(u8, second, marker)) .shortcut else .foreign;
}

pub fn add(
    ports: std.fs.Dir,
    artwork: ?std.fs.Dir,
    shortcut: Shortcut,
    name: []const u8,
    cover_png: ?[]const u8,
) !void {
    var script_buffer: [name_capacity + 8]u8 = undefined;
    const script_name = try std.fmt.bufPrint(&script_buffer, "{s}.sh", .{name});
    if (state(ports, script_name) == .foreign) return error.NameInUse;

    var content = std.ArrayList(u8).init(std.heap.page_allocator);
    defer content.deinit();
    try writeScript(content.writer(), shortcut, name);
    try writeAtomic(ports, script_name, content.items, 0o755);

    const directory = artwork orelse return;
    const png = cover_png orelse return;
    var cover_buffer: [name_capacity + 8]u8 = undefined;
    const cover_name = try std.fmt.bufPrint(&cover_buffer, "{s}.png", .{name});
    writeAtomic(directory, cover_name, png, 0o644) catch |err|
        std.debug.print("Shortcut artwork could not be saved: {s}\n", .{@errorName(err)});
}

pub fn remove(ports: std.fs.Dir, artwork: ?std.fs.Dir, name: []const u8) !void {
    var script_buffer: [name_capacity + 8]u8 = undefined;
    const script_name = try std.fmt.bufPrint(&script_buffer, "{s}.sh", .{name});
    if (state(ports, script_name) != .shortcut) return error.NotAShortcut;
    try ports.deleteFile(script_name);
    const directory = artwork orelse return;
    var cover_buffer: [name_capacity + 8]u8 = undefined;
    const cover_name = try std.fmt.bufPrint(&cover_buffer, "{s}.png", .{name});
    directory.deleteFile(cover_name) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn writeAtomic(directory: std.fs.Dir, name: []const u8, data: []const u8, mode: std.fs.File.Mode) !void {
    var temporary_buffer: [name_capacity + 16]u8 = undefined;
    const temporary = try std.fmt.bufPrint(&temporary_buffer, "{s}.tmp", .{name});
    errdefer directory.deleteFile(temporary) catch {};
    var file = try directory.createFile(temporary, .{ .truncate = true });
    var closed = false;
    defer if (!closed) file.close();
    try file.writeAll(data);
    // The port launcher runs under umask 077; frontends need to read and run shortcuts.
    try file.chmod(mode);
    try file.sync();
    file.close();
    closed = true;
    try directory.rename(temporary, name);
}

test "port names keep readable titles and drop unsafe characters" {
    var buffer: [name_capacity]u8 = undefined;
    try std.testing.expectEqualStrings("CONTROL Resonant", portName(&buffer, "CONTROL Resonant"));
    try std.testing.expectEqualStrings(
        "Ori and the Will of the Wisps",
        portName(&buffer, "Ori and the Will of the Wisps\xe2\x84\xa2"),
    );
    try std.testing.expectEqualStrings("Fallout 4 GOTY", portName(&buffer, "Fallout 4: GOTY"));
    try std.testing.expectEqualStrings("Aerial Knight's Never Yield", portName(&buffer, "Aerial Knight's  Never Yield"));
    try std.testing.expectEqualStrings("AC DC", portName(&buffer, " ../AC/DC\"*?. "));
    try std.testing.expectEqualStrings("", portName(&buffer, "\xe5\x8e\x9f\xe7\xa5\x9e"));
    const long = portName(&buffer, "A" ** 100);
    try std.testing.expectEqual(@as(usize, name_capacity), long.len);
}

test "shortcut script relaunches the port launcher straight into the title" {
    var output = std.ArrayList(u8).init(std.testing.allocator);
    defer output.deinit();
    try writeScript(output.writer(), .{
        .launcher = "/mnt/sdcard/ROMS/PORTS/GreenOvercast.sh",
        .service = .geforce_now,
        .product_id = "a1b2-C3",
    }, "CONTROL");
    try std.testing.expectEqualStrings(
        "#!/bin/bash\n" ++ marker ++ "\n# CONTROL\n" ++
            "export GREENOVERCAST_SERVICE=geforce-now\n" ++
            "export GREENOVERCAST_AUTOSTART=1\n" ++
            "exec /bin/bash '/mnt/sdcard/ROMS/PORTS/GreenOvercast.sh' 'a1b2-C3'\n",
        output.items,
    );
}

test "shortcut script rejects values that would break shell quoting" {
    var output = std.ArrayList(u8).init(std.testing.allocator);
    defer output.deinit();
    const base = Shortcut{ .launcher = "/roms/ports/GreenOvercast.sh", .service = .xbox, .product_id = "9NBLGGH4R315" };
    var shortcut = base;
    shortcut.launcher = "/roms/ports/it's/GreenOvercast.sh";
    try std.testing.expectError(error.InvalidLauncher, writeScript(output.writer(), shortcut, "X"));
    shortcut = base;
    shortcut.launcher = "ports/GreenOvercast.sh";
    try std.testing.expectError(error.InvalidLauncher, writeScript(output.writer(), shortcut, "X"));
    shortcut = base;
    shortcut.product_id = "id' ; rm -rf /";
    try std.testing.expectError(error.InvalidProductId, writeScript(output.writer(), shortcut, "X"));
}

test "shortcuts are added and removed without touching other ports" {
    var ports = std.testing.tmpDir(.{});
    defer ports.cleanup();
    var artwork = std.testing.tmpDir(.{});
    defer artwork.cleanup();
    const shortcut = Shortcut{
        .launcher = "/roms/ports/GreenOvercast.sh",
        .service = .xbox,
        .product_id = "9NBLGGH4R315",
    };

    try add(ports.dir, artwork.dir, shortcut, "Halo", "png-bytes");
    try std.testing.expectEqual(State.shortcut, state(ports.dir, "Halo.sh"));
    const stat = try ports.dir.statFile("Halo.sh");
    try std.testing.expectEqual(@as(std.fs.File.Mode, 0o755), stat.mode & 0o777);
    var cover_buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("png-bytes", try artwork.dir.readFile("Halo.png", &cover_buffer));

    try ports.dir.writeFile(.{ .sub_path = "Celeste.sh", .data = "#!/bin/bash\n# PortMaster\n" });
    try std.testing.expectError(error.NameInUse, add(ports.dir, null, shortcut, "Celeste", null));
    try std.testing.expectError(error.NotAShortcut, remove(ports.dir, null, "Celeste"));
    try std.testing.expectEqual(State.foreign, state(ports.dir, "Celeste.sh"));

    try remove(ports.dir, artwork.dir, "Halo");
    try std.testing.expectEqual(State.absent, state(ports.dir, "Halo.sh"));
    try std.testing.expectError(error.FileNotFound, artwork.dir.access("Halo.png", .{}));
}
