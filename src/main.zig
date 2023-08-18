const w4 = @import("wasm4.zig");
const tiles = @import("gfx.zig");

const Tile = enum {
    None,
    Brick,
    BrickHard,
    BrickFake,
    Ladder,
    LadderWin,
    Rope,
    Gold,

    const Self = @This();

    fn draw(self: Self, x: i32, y: i32) void {
        switch (self) {
            .None, .LadderWin => {},
            .Brick, .BrickFake => {
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

    fn isSolid(self: Self) bool {
        return switch (self) {
            .Brick, .BrickHard, .Ladder => true,
            else => false,
        };
    }
    fn isBrick(self: Self) bool {
        return switch (self) {
            .Brick, .BrickHard => true,
            else => false,
        };
    }
};

const BrickState = enum {
    Normal,
    Breaking,
    Broken,
};

const Level = struct {
    terrain: [18][20]Tile,
    spawn: i16,
    enemies: [4]?i16,

    const Self = @This();

    fn draw(self: Self) void {
        for (self.terrain, 0..) |row, y| {
            for (row, 0..) |tile, x| {
                tile.draw(@intCast(x * 8), @intCast(y * 8));
            }
        }
    }
    fn isCollected(self: Self) bool {
        for (self.terrain) |row| {
            for (row) |tile| {
                if (tile == .Gold) return false;
            }
        }
        return true;
    }
    fn open(self: *Self) void {
        for (&self.terrain) |*row| {
            for (row) |*tile| {
                if (tile.* == .LadderWin) tile.* = .Ladder;
            }
        }
    }
};

const Direction = enum {
    Right,
    Left,
};

const Jeff = struct {
    facing: Direction = .Right,
    pos: i32,

    const Self = @This();

    fn draw(self: Self) void {
        w4.DRAW_COLORS.* = 0x10;

        if (self.getTile(5) == .Ladder and self.getTile(2) == .Ladder) {
            tiles.jeff[4]
                .draw(
                @mod(self.pos, 160),
                @divFloor(self.pos, 160),
                .{ .flip_x = self.facing == .Left },
            );
            return;
        }
        // Cycles sprite every 8 pixels
        // 0, 1 are walk sprites
        // 2, 3 are climb sprites
        const offset: i32 = if (self.onRope()) 2 else 0;
        tiles.jeff[@intCast(@mod(@divFloor(self.pos, 8), 2) + offset)]
            .draw(
            @mod(self.pos, 160),
            @divFloor(self.pos, 160),
            .{ .flip_x = self.facing == .Left },
        );
    }

    fn getXpx(self: Self) i32 {
        return @mod(self.pos, 160);
    }

    fn getYpx(self: Self) i32 {
        return @divFloor(self.pos, 160);
    }

    fn getBottomY(self: Self) i32 {
        return @divFloor(self.pos, 160 * 8);
    }

    fn getX(self: Self) i32 {
        return @divFloor(@mod(self.pos + 3, 160), 8);
    }

    fn getY(self: Self) i32 {
        return @divFloor(self.pos, 160 * 8);
    }

    fn setX(self: *Self, x: i32) void {
        self.pos = self.getYpx() * 160 + (x * 8);
    }

    fn setY(self: *Self, y: i32) void {
        self.pos = (y * 160 * 8) + self.getXpx();
    }

    // Direction is fighting game numpad notation
    fn getTile(self: Self, comptime direction: u4) Tile {
        if (direction > 9) {
            @compileError("direction exceeded 9");
        }
        const dx =
            if (@mod(direction, 3) == 0) 1 else if (direction == 5 or direction == 2 or direction == 8) 0 else -1;
        const dy = if (direction <= 3) 1 else if (direction >= 7) -1 else 0;

        return level.terrain //
        [@intCast(self.getY() + dy)] //
        [@intCast(self.getX() + dx)];
    }
    fn setTile(self: *Self, comptime direction: u4, tile: Tile) void {
        if (direction > 9) {
            @compileError("direction exceeded 9");
        }
        const dx =
            if (@mod(direction, 3) == 0) 1 else if (direction == 5 or @mod(direction, 2) == 0) 0 else -1;
        const dy = if (direction <= 3) 1 else if (direction >= 7) -1 else 0;

        level.terrain //
        [@intCast(self.getY() + dy)] //
        [@intCast(self.getX() + dx)] = tile;
    }

    fn currentTile(self: Self) *Tile {
        return &level.terrain //
        [@intCast(self.getY())] //
        [@intCast(self.getX())];
    }

    fn underTile(self: Self) Tile {
        return self.getTile(2);
    }

    fn overTile(self: Self) Tile {
        return self.getTile(8);
    }

    fn onLadder(self: Self) bool {
        return self.getTile(5) == .Ladder or self.underTile() == .Ladder;
    }

    fn onRope(self: Self) bool {
        return self.getTile(5) == .Rope and @mod(self.getYpx(), 8) == 0;
    }

    fn isFalling(self: Self) bool {
        return !self.underTile().isSolid() and !self.onRope() and !self.onLadder() and self.getY() != 17;
    }

    fn snapX(self: *Self) void {
        self.setX(self.getX());
    }

    fn snapY(self: *Self) void {
        self.setY(self.getY());
    }

    fn destroyBrick(self: *Self, direction: Direction) void {
        switch (direction) {
            .Left => {
                if (self.getTile(1) == .Brick) {
                    self.snapX();
                    self.setTile(1, .None);
                }
            },
            .Right => {
                if (self.getTile(3) == .Brick) {
                    self.snapY();
                    self.setTile(3, .None);
                }
            },
        }
    }

    fn handleInput(self: *Self) void {
        if (player.isFalling()) {
            player.snapX();
            player.pos += 160;
            return;
        }

        const gamepad = w4.GAMEPAD1.*;

        if (gamepad & w4.BUTTON_UP != 0 and self.onLadder() and (!self.overTile().isBrick() or @mod(self.getYpx(), 8) != 0)) {
            self.pos -= 160;
            self.facing = if (@mod(self.getY(), 2) == 0) .Left else .Right;

            // Prevents jitter on top of ladders
            if (self.underTile() != .Ladder) {
                self.pos += 160;
            }
        } else if (gamepad & w4.BUTTON_DOWN != 0 and self.getY() != 17 and !self.underTile().isBrick()) {
            self.pos += 160;
        } else if (gamepad & w4.BUTTON_DOWN != 0 and self.onRope()) {
            self.pos += 160;
        } else if (gamepad & w4.BUTTON_LEFT != 0 and !((self.getX() == 0 or self.getTile(4).isBrick()) and @mod(self.getXpx(), 8) == 0)) {
            // self.snapY();
            self.facing = .Left;
            self.pos -= 1;
        } else if (gamepad & w4.BUTTON_RIGHT != 0 and !((self.getX() == 19 or self.getTile(6).isBrick()) and @mod(self.getXpx(), 8) == 0)) {
            self.facing = .Right;
            self.pos += 1;
        }
        if (gamepad & w4.BUTTON_2 != 0) {
            self.destroyBrick(.Left);
        }
        if (gamepad & w4.BUTTON_1 != 0) {
            self.destroyBrick(.Right);
        }
        if (self.onLadder() and (gamepad & w4.BUTTON_UP != 0 or gamepad & w4.BUTTON_DOWN != 0)) {
            self.snapX();
        } else if (self.onLadder() and (gamepad & w4.BUTTON_LEFT != 0 or gamepad & w4.BUTTON_RIGHT != 0)) {
            self.snapY();
        }
    }
};

var level: Level = undefined;
var player: Jeff = undefined;

export fn update() void {
    // Clear screen with color 4
    w4.DRAW_COLORS.* = 4;
    w4.rect(0, 0, 160, 160);

    println(150, "{},{}", .{ player.getX(), player.getY() });

    level.draw();

    player.handleInput();
    player.draw();

    w4.DRAW_COLORS.* = 1;
    w4.rect(0, 143, 160, 1);

    if (player.getTile(5) == .Gold) {
        player.setTile(5, .None);
    }
    if (level.isCollected()) level.open();
    if (player.getYpx() == 0) w4.text("win", 80, 100);
}

export fn start() void {
    for (&level.terrain, 0..) |*row, y| {
        for (row, 0..) |*tile, x| {
            if (x == 2 and y != 17 and y > 1) tile.* = .Ladder;
            if (y == 17) tile.* = .Brick;
            if (y == 0 and x < 5) tile.* = .Brick;
            if (y == 2) tile.* = .Ladder;
            if (y == 1 and x == 16) tile.* = .LadderWin;
            if (y == 0 and x == 16) tile.* = .LadderWin;

            if (x > 2 and y == 5) tile.* = .Rope;

            if (x < 2 and y == 9) tile.* = .BrickFake;
            if (x > 2 and y == 8) tile.* = .BrickHard;
            if (x == 16 and y == 8) tile.* = .Ladder;
            if (x == 6 and y == 7) tile.* = .Gold;
            if (x == 7 and y == 7) tile.* = .Gold;
            if (x == 16 and y == 10) tile.* = .Gold;
        }
    }
    level.terrain[1][2] = .Brick;
    level.spawn = 16 * (160 * 8) + (4 * 8);

    player.pos = level.spawn;
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
