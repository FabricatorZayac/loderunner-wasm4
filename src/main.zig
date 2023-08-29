const std = @import("std");
const w4 = @import("wasm4.zig");
const tiles = @import("gfx.zig");

const SCREEN_SIZE = 160;

fn println(
    y: i32,
    comptime fmt: []const u8,
    args: anytype,
) void {
    var buf: [20]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);

    std.fmt.format(stream.writer(), fmt, args) catch unreachable;

    w4.DRAW_COLORS.* = 1;
    w4.text(stream.getWritten(), 2, y);
}

const TileTag = enum(u3) {
    None,
    Brick,
    BrickHard,
    BrickFake,
    Ladder,
    LadderWin,
    Rope,
    Gold,
};
const Tile = union(TileTag) {
    None: void,
    Brick: u16, // 0 is solid, 65535 is freshly dug. Decrement every tick
    BrickHard: void,
    BrickFake: void,
    Ladder: void,
    LadderWin: void,
    Rope: void,
    Gold: void,

    const Self = @This();

    fn fromTag(tag: TileTag) Self {
        return switch (tag) {
            .Brick => Tile.Brick(),
            .None => .None,
            .BrickHard => .BrickHard,
            .BrickFake => .BrickFake,
            .Ladder => .Ladder,
            .LadderWin => .LadderWin,
            .Rope => .Rope,
            .Gold => .Gold,
        };
    }
    fn draw(self: Self, x: i32, y: i32) void {
        switch (self) {
            .None, .LadderWin => {},
            .Brick => |state| {
                switch (state) {
                    0 => {
                        w4.DRAW_COLORS.* = 0x3;
                        tiles.brick.draw(x, y, .{});
                    },
                    // TODO: Draw better sprites, because these kinda suck huh
                    1...10, 190...200 => {
                        w4.DRAW_COLORS.* = 0x10;
                        tiles.powder[1].draw(x, y, .{});
                    },
                    else => {},
                }
            },
            .BrickFake => {
                w4.DRAW_COLORS.* = 0x3;
                tiles.brick.draw(x, y, .{});
            },
            .BrickHard => {
                w4.DRAW_COLORS.* = 0x13;
                tiles.brick_hard.draw(x, y, .{});
            },
            .Ladder => {
                w4.DRAW_COLORS.* = 0x20;
                tiles.ladder.draw(x, y, .{});
            },
            .Rope => {
                w4.DRAW_COLORS.* = 0x10;
                tiles.rope.draw(x, y, .{});
            },
            .Gold => {
                w4.DRAW_COLORS.* = 0x210;
                tiles.gold.draw(x, y, .{});
            },
        }
    }
    fn isBrick(self: Self) bool {
        return switch (self) {
            .Brick => |state| blk: {
                break :blk if (state == 0) true else false;
            },
            .BrickHard => true,
            else => false,
        };
    }
    fn Brick() Self {
        return Self{ .Brick = 0 };
    }
};

const LevelState = struct {
    const GRID_HEIGHT = 18;
    const GRID_WIDTH = 20;
    terrain: [GRID_HEIGHT * GRID_WIDTH]Tile,
    player: Jeff, // positions can't be more than 160 * 160 = 25600
    enemies: [4]?Jeff,

    const Self = @This();

    fn getTile(self: Self, x: usize, y: usize) Tile {
        return self.terrain[y * GRID_WIDTH + x];
    }
    fn setTile(self: *Self, x: usize, y: usize, newtile: Tile) void {
        self.terrain[y * GRID_WIDTH + x] = newtile;
    }
    fn draw(self: Self) void {
        for (self.terrain, 0..) |tile, pos| {
            tile.draw(
                @intCast(@mod(pos, GRID_WIDTH) * 8),
                @intCast(@divFloor(pos, GRID_WIDTH) * 8),
            );
        }
        self.player.draw(0x10);
        for (self.enemies) |opt_jeff| {
            if (opt_jeff) |jeff| {
                jeff.draw(0x40);
            }
        }
    }
    fn update(self: *Self) void {
        for (&self.terrain) |*tile| {
            if (tile.* == .Brick and tile.Brick > 0) {
                tile.Brick -= 1;
            }
        }
    }
    fn isCollected(self: Self) bool {
        for (self.terrain) |tile| {
            if (tile == .Gold) return false;
        }
        return true;
    }
    fn open(self: *Self) void {
        for (&self.terrain) |*tile| {
            if (tile.* == .LadderWin) tile.* = .Ladder;
        }
    }
    // Math time
    // u3 * (18 * 20 = 360) = 1080bit = 135 bytes // terrain repr
    // u16 = 2 bytes // player spawn
    // 4 * u16 = 8 bytes // enemy spawns
    // 135 + 2 + 8 = 145 total bytes
    const Batch = packed struct {
        a: TileTag,
        b: TileTag,
        c: TileTag,
        d: TileTag,
        e: TileTag,
        f: TileTag,
        g: TileTag,
        h: TileTag,
    };
    fn dump(self: Self) [145]u8 {
        var terrain_data: [135]u8 = undefined;
        {
            var batch: Batch = undefined;
            var cursor: usize = 0; // cursor into terrain_data
            var i: usize = 0;
            // need 135byte / 3byte (24bit) = 45 batches
            // 360tiles / 45batches = 8 per batch
            while (cursor < 135) : ({
                cursor += 3;
                i += 8;
            }) {
                // could probably do this in a loop or something, but
                // FUCK manual bit shifting
                batch = .{
                    .a = self.terrain[i + 0],
                    .b = self.terrain[i + 1],
                    .c = self.terrain[i + 2],
                    .d = self.terrain[i + 3],
                    .e = self.terrain[i + 4],
                    .f = self.terrain[i + 5],
                    .g = self.terrain[i + 6],
                    .h = self.terrain[i + 7],
                };
                const batchptr: *[3]u8 = @ptrCast(&batch);
                terrain_data[cursor + 0] = batchptr[0];
                terrain_data[cursor + 1] = batchptr[1];
                terrain_data[cursor + 2] = batchptr[2];
            }
        }

        var out: [145]u8 = undefined;
        for (terrain_data, 0..) |byte, i| {
            out[i] = byte;
        }

        const spawn_data: [2]u8 = @bitCast(self.player.pos);
        out[135] = spawn_data[0];
        out[136] = spawn_data[1];

        // TODO: Enemies

        return out;
    }
    fn parse(data: [145]u8) Self {
        var self: Self = undefined;
        {
            var cursor: usize = 0; // cursor into terrain_data
            var i: usize = 0;
            while (cursor < 135) : ({
                cursor += 3;
                i += 8;
            }) {
                const batchptr: *const Batch = @alignCast(@ptrCast(&data[cursor]));
                self.terrain[i + 0] = Tile.fromTag(batchptr.a);
                self.terrain[i + 1] = Tile.fromTag(batchptr.b);
                self.terrain[i + 2] = Tile.fromTag(batchptr.c);
                self.terrain[i + 3] = Tile.fromTag(batchptr.d);
                self.terrain[i + 4] = Tile.fromTag(batchptr.e);
                self.terrain[i + 5] = Tile.fromTag(batchptr.f);
                self.terrain[i + 6] = Tile.fromTag(batchptr.g);
                self.terrain[i + 7] = Tile.fromTag(batchptr.h);
            }
        }

        const spawn_ptr: *[2]u8 = @ptrCast(&self.player.pos);
        spawn_ptr[0] = data[135];
        spawn_ptr[1] = data[136];

        // TODO: Enemies

        return self;
    }
    fn asBase64(self: Self) [194]u8 {
        const encoder = comptime std.base64.Base64Encoder.init(
            std.base64.standard_alphabet_chars,
            null,
        );
        var buf: [194]u8 = undefined;
        _ = encoder.encode(&buf, &self.dump());
        return buf;
    }
    fn fromBase64(string: []const u8) Self {
        const decoder = std.base64.Base64Decoder.init(
            std.base64.standard_alphabet_chars,
            null,
        );
        var level_data: [145]u8 = undefined;
        decoder.decode(&level_data, string) catch unreachable;
        return Self.parse(level_data);
    }
    fn gameLoop(self: *Self) void {
        w4.DRAW_COLORS.* = 1;
        w4.rect(0, 143, SCREEN_SIZE, 1);

        println(150, "{},{}", .{ self.player.getX(), self.player.getY() });

        self.update();
        self.player.handleInput();

        self.draw();

        if (self.player.getTile(5) == .Gold) {
            self.player.setTile(5, .None);
        }
        if (self.isCollected()) {
            self.open();
        }
    }
};

const Direction = enum {
    Right,
    Left,
};

const Jeff = struct {
    pos: i16,
    direction: Direction = .Right,

    const Self = @This();

    fn draw(self: Self, color: u16) void {
        w4.DRAW_COLORS.* = color;

        if (self.getTile(5) == .Ladder) {
            tiles.jeff[4]
                .draw(
                @mod(self.pos, SCREEN_SIZE),
                @divFloor(self.pos, SCREEN_SIZE),
                .{ .flip_x = self.direction == .Left },
            );
            return;
        }
        // Cycles sprite every 8 pixels
        // 0, 1 are walk sprites
        // 2, 3 are climb sprites
        const offset: i32 = if (self.onRope()) 2 else 0;
        tiles.jeff[@intCast(@mod(@divFloor(self.pos, 8), 2) + offset)]
            .draw(
            @mod(self.pos, SCREEN_SIZE),
            @divFloor(self.pos, SCREEN_SIZE),
            .{ .flip_x = self.direction == .Left },
        );
    }

    fn getXpx(self: Self) i32 {
        return @mod(self.pos, SCREEN_SIZE);
    }

    fn getYpx(self: Self) i32 {
        return @divFloor(self.pos, SCREEN_SIZE);
    }

    fn getX(self: Self) i32 {
        const xpx = self.getXpx();
        const x = @divFloor(xpx, 8);
        return switch (@mod(xpx, 8)) {
            0...3 => x,
            4...7 => x + 1,
            else => unreachable,
        };
    }

    fn getY(self: Self) i32 {
        const ypx = self.getYpx();
        const y = @divFloor(ypx, 8);
        return switch (@mod(ypx, 8)) {
            0...3 => y,
            4...7 => y + 1,
            else => unreachable,
        };
    }

    fn setX(self: *Self, x: i32) void {
        self.pos = @intCast(self.getYpx() * SCREEN_SIZE + (x * 8));
    }

    fn setY(self: *Self, y: i32) void {
        self.pos = @intCast((y * SCREEN_SIZE * 8) + self.getXpx());
    }

    // Direction is fighting game numpad notation
    fn getTile(self: Self, comptime direction: u4) Tile {
        if (direction > 9) {
            @compileError("direction exceeded 9");
        }
        const dx = if (@mod(direction, 3) == 0) 1 else if (direction == 5 or direction == 2 or direction == 8) 0 else -1;
        const dy = if (direction <= 3) 1 else if (direction >= 7) -1 else 0;

        return level.getTile(
            @intCast(self.getX() + dx),
            @intCast(self.getY() + dy),
        );
    }
    fn setTile(self: *Self, comptime direction: u4, tile: Tile) void {
        if (direction > 9) {
            @compileError("direction exceeded 9");
        }
        const dx = if (@mod(direction, 3) == 0) 1 else if (direction == 5 or @mod(direction, 2) == 0) 0 else -1;
        const dy = if (direction <= 3) 1 else if (direction >= 7) -1 else 0;

        level.setTile(
            @intCast(self.getX() + dx),
            @intCast(self.getY() + dy),
            tile,
        );
    }

    fn currentTile(self: Self) Tile {
        return self.getTile(5);
    }

    fn underTile(self: Self) Tile {
        return self.getTile(2);
    }

    fn overTile(self: Self) Tile {
        return self.getTile(8);
    }

    fn onLadder(self: Self) bool {
        return self.getTile(5) == .Ladder;
    }

    fn onRope(self: Self) bool {
        return self.getTile(5) == .Rope and self.isAlignedY();
    }

    fn isFalling(self: Self) bool {
        return !self.onRope() //
        and !self.onLadder() //
        and !((self.underTile() == .Ladder or self.underTile().isBrick() or self.getY() == LevelState.GRID_HEIGHT - 1) and self.isAlignedY());
    }

    fn snapX(self: *Self) void {
        self.setX(self.getX());
    }

    fn snapY(self: *Self) void {
        self.setY(self.getY());
    }

    fn isAlignedX(self: Self) bool {
        return @mod(self.getXpx(), 8) == 0;
    }

    fn isAlignedY(self: Self) bool {
        return @mod(self.getYpx(), 8) == 0;
    }

    fn dig(self: *Self, comptime direction: Direction) void {
        const pos = switch (direction) {
            .Left => 1,
            .Right => 3,
        };
        // because of numpad notation you can just add 3 to get the above block
        if (self.getTile(pos + 3) == .Ladder or self.getTile(pos + 3) == .LadderWin) {
            return;
        }
        const target = self.getTile(pos);
        if (target == .Brick and target.Brick == 0) {
            self.setTile(pos, .{ .Brick = 200 });
        }
    }

    fn handleInput(self: *Self) void {
        if (level.player.isFalling()) {
            level.player.snapX();
            level.player.pos += SCREEN_SIZE;
            return;
        }

        const gamepad = w4.GAMEPAD1.*;

        if (self.currentTile() == .Ladder and (gamepad & w4.BUTTON_UP != 0 or gamepad & w4.BUTTON_DOWN != 0)) {
            self.snapX();
        } else if (gamepad & w4.BUTTON_LEFT != 0 or gamepad & w4.BUTTON_RIGHT != 0) {
            self.snapY();
        }

        if (gamepad & w4.BUTTON_UP != 0 and self.onLadder() and !(self.overTile().isBrick() and self.isAlignedY())) {
            self.pos -= SCREEN_SIZE;
            self.direction = if (@mod(self.getY(), 2) == 0) .Left else .Right;

            // Prevents jitter on top of ladders
            if (!self.onLadder()) {
                self.pos += SCREEN_SIZE;
                self.setY(self.getY() - 1);
            }
        } else if (gamepad & w4.BUTTON_DOWN != 0 and self.getY() < LevelState.GRID_HEIGHT and !(self.underTile().isBrick() and self.isAlignedY())) {
            self.pos += SCREEN_SIZE;
        } else if (gamepad & w4.BUTTON_DOWN != 0 and self.onRope()) {
            self.pos += SCREEN_SIZE;
        } else if (gamepad & w4.BUTTON_LEFT != 0 and !((self.getX() == 0 or self.getTile(4).isBrick()) and self.isAlignedX())) {
            self.direction = .Left;
            self.pos -= 1;
        } else if (gamepad & w4.BUTTON_RIGHT != 0 and !((self.getX() == LevelState.GRID_WIDTH - 1 or self.getTile(6).isBrick()) and self.isAlignedX())) {
            self.direction = .Right;
            self.pos += 1;
        }

        if (gamepad & w4.BUTTON_1 != 0) {
            self.dig(.Right);
        } else if (gamepad & w4.BUTTON_2 != 0) {
            self.dig(.Left);
        }
    }
};

// TODO: fix mess of global state
var level: *LevelState = undefined;

export fn start() void {}
export fn update() void {
    level = &game.Level;

    // Clear screen with color 4
    w4.DRAW_COLORS.* = 4;
    w4.rect(0, 0, SCREEN_SIZE, 160);

    switch (game) {
        .Menu => menu(),
        .Level => level.gameLoop(),
        // .Level => |*state| state.gameLoop(), // idk why this doesn't work
        .LevelTransition => {},
        .Editor => {},
    }
}

const levels = [_][]const u8{
    "SRIAAAAABQAEAAAAAFAAJEmSJEmSJAkQAAAAAAAAAAEAAAAAAADQtm3btm3bAAEAAAAAAAAQwA8AAAAAACUpkiRJlLQRAAAAAAAAAAHgAAAABwAQAAAAAAAAAAEAAAAAAAAQAAAAAAAAAAEAAAAAAAAQAAAAAAAAAAEAAAAAAJAkSZIkSZIkIFAAAAAAAAAAAA",
};

const MenuState = enum {
    Start,
    Editor,
};
const GameState = union(enum) {
    Menu: MenuState,
    Level: LevelState,
    LevelTransition: void,
    Editor: void,
};
var game = GameState{ .Menu = .Start };

fn menu() void {
    w4.DRAW_COLORS.* = 0x14;
    w4.rect(30, 60, 100, 38);
    w4.DRAW_COLORS.* = 1;
    w4.text("Start game", 42, 65);
    w4.text("Editor", 42, 85);
    const cursor_y: i32 = switch (game.Menu) {
        .Start => 65,
        .Editor => 85,
    };
    w4.text(">", 33, cursor_y);

    const gamepad = w4.GAMEPAD1.*;
    if (gamepad & w4.BUTTON_UP != 0) {
        game.Menu = .Start;
    } else if (gamepad & w4.BUTTON_DOWN != 0) {
        game.Menu = .Editor;
    } else if (gamepad & w4.BUTTON_1 != 0) {
        game = .{ .Level = LevelState.fromBase64(levels[0]) };
        // TODO: make it so the pressed button doesn't get transferred into the
        // game input if held for longer than 1 frame
    }
}

fn editor() void {}
