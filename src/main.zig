const w4 = @import("wasm4.zig");
const tiles = @import("gfx.zig");

const SCREEN_SIZE = 160;

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

const Level = struct {
    const GRID_HEIGHT = 18;
    const GRID_WIDTH = 20;
    terrain: [GRID_HEIGHT * GRID_WIDTH]Tile,
    spawn: u16, // positions can't be more than 160 * 160 = 25600
    enemies: [4]?u16,

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
    fn initPlayer(self: Self) Jeff {
        return .{ .pos = self.spawn };
    }
    // Math time
    // u3 * 18 * 20 = 1080bit = 135 bytes // terrain repr
    // u16 = 2 bytes // player spawn
    // 4 * u16 = 8 bytes // enemy spawns
    // 135 + 2 + 8 = 145 total bytes
    fn dump(self: Self) [145]u8 {
        var terrain_data: [135]u8 = undefined;
        {
            // need 135byte / 3byte (24bit) = 45 batches
            var cursor: usize = 0;
            while (cursor < 135) : (cursor += 3) {
                const batch_ptr: *[8]u3 = @ptrCast(&terrain_data[cursor]);
                for (batch_ptr) |*tile| {
                    // for each in batch
                    _ = tile;
                }
            }
        }

        const spawn_data: [2]u8 = @bitCast(self.spawn);

        // idk man
        // var enemy_data: [8]u8 = undefined;
        // {
        //     var i: usize = 0;
        //     for (self.enemies) |enemy| {
        //         enemy_data[i] = if (enemy == null) 0x0000 else @bitCast(enemy);
        //     }
        // }

        var out: [145]u8 = undefined;
        out[135] = spawn_data[0];
        out[136] = spawn_data[1];
        // for (enemy_data, 137..145) |byte, i| {
        //     out[i] = byte;
        // }

        return out;
    }
};

const Direction = enum {
    Right,
    Left,
};

const Jeff = struct {
    direction: Direction = .Right,
    pos: i32,

    const Self = @This();

    fn draw(self: Self) void {
        w4.DRAW_COLORS.* = 0x10;

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
        self.pos = self.getYpx() * SCREEN_SIZE + (x * 8);
    }

    fn setY(self: *Self, y: i32) void {
        self.pos = (y * SCREEN_SIZE * 8) + self.getXpx();
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
        and !((self.underTile() == .Ladder or self.underTile().isBrick() or self.getY() == Level.GRID_HEIGHT - 1) and self.isAlignedY());
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
        if (player.isFalling()) {
            player.snapX();
            player.pos += SCREEN_SIZE;
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
        } else if (gamepad & w4.BUTTON_DOWN != 0 and self.getY() < Level.GRID_HEIGHT and !(self.underTile().isBrick() and self.isAlignedY())) {
            self.pos += SCREEN_SIZE;
        } else if (gamepad & w4.BUTTON_DOWN != 0 and self.onRope()) {
            self.pos += SCREEN_SIZE;
        } else if (gamepad & w4.BUTTON_LEFT != 0 and !((self.getX() == 0 or self.getTile(4).isBrick()) and self.isAlignedX())) {
            self.direction = .Left;
            self.pos -= 1;
        } else if (gamepad & w4.BUTTON_RIGHT != 0 and !((self.getX() == Level.GRID_WIDTH - 1 or self.getTile(6).isBrick()) and self.isAlignedX())) {
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

var level: Level = undefined;
var player: Jeff = undefined;

export fn update() void {
    // Clear screen with color 4
    w4.DRAW_COLORS.* = 4;
    w4.rect(0, 0, SCREEN_SIZE, 160);

    println(150, "{},{}", .{ player.getX(), player.getY() });

    level.update();
    level.draw();

    player.handleInput();
    player.draw();

    w4.DRAW_COLORS.* = 1;
    w4.rect(0, 143, SCREEN_SIZE, 1);

    if (player.getTile(5) == .Gold) {
        player.setTile(5, .None);
    }
    if (level.isCollected()) level.open();
    if (player.getYpx() == 0) start();
}

export fn start() void {
    for (&level.terrain, 0..) |*tile, pos| {
        const x = @mod(pos, Level.GRID_WIDTH);
        const y = @divFloor(pos, Level.GRID_WIDTH);
        if (x == 2 and y != 17 and y > 1) tile.* = .Ladder;
        if (y == 17) tile.* = Tile.Brick();
        if (y == 0 and x < 5) tile.* = Tile.Brick();
        if (y == 2) tile.* = .Ladder;
        if (y == 1 and x == 16) tile.* = .LadderWin;
        if (y == 0 and x == 16) tile.* = .LadderWin;

        if (x > 2 and y == 5) tile.* = .Rope;

        if (x < 2 and y == 9) tile.* = .BrickFake;
        if (x > 2 and y == 8) tile.* = .BrickHard;
        if (x == 7 and y == 8) tile.* = Tile.Brick();
        if (x == 16 and y == 8) tile.* = .Ladder;
        if (x == 6 and y == 7) tile.* = .Gold;
        if (x == 7 and y == 7) tile.* = .Gold;
        if (x == 7 and y == 10) tile.* = .Gold;
        if (x == 16 and y == 10) tile.* = .Gold;
    }
    level.setTile(2, 1, Tile.Brick());
    level.spawn = 16 * (SCREEN_SIZE * 8) + (4 * 8);
    player = level.initPlayer();

    // w4.trace(&level.dump());
}

const std = @import("std");
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
