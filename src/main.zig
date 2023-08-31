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
    Brick: u16,
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
    fn draw(self: Self, x: i32, y: i32, mode: GameStateTag) void {
        switch (self) {
            .None => {},
            .LadderWin => {
                if (mode == .Editor) {
                    w4.DRAW_COLORS.* = 0x2;
                    tiles.ladder.draw(x, y, .{});
                }
            },
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
                if (mode == .Editor) {
                    w4.DRAW_COLORS.* = 0x1;
                    w4.line(x, y, x + 7, y + 6);
                }
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
    player: Jeff,
    enemies: [4]?Jeff,

    const Self = @This();

    fn getTile(self: Self, x: usize, y: usize) Tile {
        return self.terrain[y * GRID_WIDTH + x];
    }
    fn setTile(self: *Self, x: usize, y: usize, newtile: Tile) void {
        self.terrain[y * GRID_WIDTH + x] = newtile;
    }
    fn draw(self: Self, mode: GameStateTag) void {
        w4.DRAW_COLORS.* = 1;
        w4.hline(0, 143, SCREEN_SIZE);
        for (self.terrain, 0..) |tile, pos| {
            tile.draw(
                @intCast(@mod(pos, GRID_WIDTH) * 8),
                @intCast(@divFloor(pos, GRID_WIDTH) * 8),
                mode,
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
                inline for (@typeInfo(Batch).Struct.fields, 0..) |field, j| {
                    @field(batch, field.name) = self.terrain[i + j];
                }
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
        // for now zero it out to prevent trash data
        for (out[137..]) |*i| {
            i.* = 0;
        }

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
                inline for (@typeInfo(Batch).Struct.fields, 0..) |field, j| {
                    self.terrain[i + j] = Tile.fromTag(@field(batchptr, field.name));
                }
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
    fn loop(self: *Self) void {
        println(150, "{},{}", .{ self.player.getX(), self.player.getY() });

        self.update();
        self.player.handleInput();

        self.draw(.Level);

        if (self.player.getTile(5) == .Gold) {
            self.player.setTile(5, .None);
        }
        if (self.isCollected()) {
            self.open();
            if (self.player.getYpx() == 0) {
                game = .LevelTransition;
            }
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

        if (self.currentTile() == .Ladder) {
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
    // NOTE: Probably a bit overcomplicated
    fn getTile(self: Self, comptime direction: u4) Tile {
        if (direction > 9) {
            @compileError("direction exceeded 9");
        }
        const dx = if (@mod(direction, 3) == 0) 1 else if (direction == 5 or direction == 2 or direction == 8) 0 else -1;
        const dy = if (direction <= 3) 1 else if (direction >= 7) -1 else 0;

        return game.Level.getTile(
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

        game.Level.setTile(
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
        if (self.isFalling()) {
            self.snapX();
            self.pos += SCREEN_SIZE;
            return;
        }

        const gamepad = GamepadState.get(0);

        if (self.currentTile() == .Ladder and (gamepad.up or gamepad.down)) {
            self.snapX();
        } else if (gamepad.left or gamepad.right) {
            self.snapY();
        }

        if (gamepad.up and self.onLadder() and !(self.overTile().isBrick() and self.isAlignedY())) {
            self.pos -= SCREEN_SIZE;
            self.direction = if (@mod(self.getY(), 2) == 0) .Left else .Right;

            // Prevents jitter on top of ladders
            if (!self.onLadder()) {
                self.pos += SCREEN_SIZE;
                self.setY(self.getY() - 1);
            }
        } else if (gamepad.down and self.getY() < LevelState.GRID_HEIGHT and !(self.underTile().isBrick() and self.isAlignedY())) {
            self.pos += SCREEN_SIZE;
        } else if (gamepad.down and self.onRope()) {
            self.pos += SCREEN_SIZE;
        } else if (gamepad.left and !((self.getX() == 0 or self.getTile(4).isBrick()) and self.isAlignedX())) {
            self.direction = .Left;
            self.pos -= 1;
        } else if (gamepad.right and !((self.getX() == LevelState.GRID_WIDTH - 1 or self.getTile(6).isBrick()) and self.isAlignedX())) {
            self.direction = .Right;
            self.pos += 1;
        }

        if (gamepad.buttons[0]) {
            self.dig(.Right);
        } else if (gamepad.buttons[1]) {
            self.dig(.Left);
        }
    }
};

var next_level: u8 = 0;

export fn start() void {}

var prev_mouse: MouseState = undefined;
export fn update() void {
    // Clear screen with color 4
    w4.DRAW_COLORS.* = 4;
    w4.rect(0, 0, SCREEN_SIZE, 160);

    switch (game) {
        .Menu => menu(),
        .Level => |*level| level.loop(),
        .LevelTransition => {
            // TODO: have a level transition animation with state and stuff
            if (next_level == levelpack.len) {
                game = .Win;
                return;
            }
            if (w4.GAMEPAD1.* & w4.BUTTON_1 != 0) return;
            game = .{ .Level = LevelState.fromBase64(levelpack[next_level]) };
            next_level += 1;
        },
        .Editor => |*editor| editor.loop(),
        .Win => {
            w4.DRAW_COLORS.* = 1;
            w4.text("Thank you", 45, 70);
            w4.text("for playing", 37, 80);
        },
        .Death => {},
    }
    prev_mouse = MouseState.get();
}

const levelpack = [_][]const u8{
    "SRIAAAAABQAEAAAAAFAAJEmSJEmSJAkQAAAAAAAAAAEAAAAAAADQtm3btm3bAAEAAAAAAAAQwA8AAAAAACUpkiRJlLQRAAAAAAAAAAHgAAAABwAQAAAAAAAAAAEAAAAAAAAQAAAAAAAAAAEAAAAAAAAQAAAAAAAAAAEAAAAAAJAkSZIkSZIkIFAAAAAAAAAAAA",
    "KAAAAAAAAIoCAAAAAACgIAAAAAAAAAoCAAAAAACgoKQkSZIkSQICAAAcAA4AIAAAwAHgAAACAAAcAA4AIAAAAADgAAACAAAAAAAAo23btm3btg0CAAAAAAAAIADgAHAAAAACAA4ABwAAIADgAHAAAAACAAAAAAAAIAAAAAAAAJAkSZIkSZIkKFAAAAAAAAAAAA",
};

const MenuState = enum {
    Start,
    Editor,
};
const GameStateTag = enum {
    Menu,
    Level,
    LevelTransition,
    Editor,
    Win,
    Death,
};
const GameState = union(GameStateTag) {
    Menu: MenuState,
    Level: LevelState,
    LevelTransition: void,
    Editor: EditorState,
    Win: void,
    Death: void,

    const Self = @This();

    fn Editor() Self {
        return .{ .Editor = .{
            .level = undefined,
            .selection = 0,
        } };
    }
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

    const gamepad = GamepadState.get(0);
    if (gamepad.up) {
        game.Menu = .Start;
    } else if (gamepad.down) {
        game.Menu = .Editor;
    } else if (gamepad.buttons[0]) {
        switch (game.Menu) {
            .Start => {
                game = .LevelTransition;
            },
            .Editor => {
                game = GameState.Editor();
            },
        }
    }
}

const MouseState = struct {
    x: i16,
    y: i16,
    buttons: struct {
        left: bool,
        right: bool,
        middle: bool,
    },

    const Self = @This();
    fn get() Self {
        return .{
            // the underflow bug was fucking hilarious btw, rewriting program memory
            .x = @min(@max(w4.MOUSE_X.*, 0), 159),
            .y = @min(@max(w4.MOUSE_Y.*, 0), 159),
            .buttons = .{
                .left = w4.MOUSE_BUTTONS.* & w4.MOUSE_LEFT != 0,
                .right = w4.MOUSE_BUTTONS.* & w4.MOUSE_RIGHT != 0,
                .middle = w4.MOUSE_BUTTONS.* & w4.MOUSE_MIDDLE != 0,
            },
        };
    }
};
const GamepadState = struct {
    buttons: [2]bool,
    up: bool,
    down: bool,
    left: bool,
    right: bool,

    const Self = @This();

    fn get(player: u2) Self {
        const gamepad = switch (player) {
            0 => w4.GAMEPAD1.*,
            1 => w4.GAMEPAD2.*,
            2 => w4.GAMEPAD3.*,
            3 => w4.GAMEPAD4.*,
        };
        return .{
            .buttons = .{
                gamepad & w4.BUTTON_1 != 0,
                gamepad & w4.BUTTON_2 != 0,
            },
            .up = gamepad & w4.BUTTON_UP != 0,
            .down = gamepad & w4.BUTTON_DOWN != 0,
            .left = gamepad & w4.BUTTON_LEFT != 0,
            .right = gamepad & w4.BUTTON_RIGHT != 0,
        };
    }
};

const EditorState = struct {
    level: LevelState,
    selection: u8,

    const Self = @This();

    fn loop(self: *Self) void {
        self.level.draw(.Editor);
        inline for (@typeInfo(TileTag).Enum.fields, 0..) |f, i| {
            Tile.fromTag(@field(TileTag, f.name))
                .draw(i * 12 + 4, 148, .Editor);
        }
        tiles.jeff[0].draw(8 * 12 + 4, 148, .{});
        w4.DRAW_COLORS.* = 0x30;
        tiles.jeff[0].draw(9 * 12 + 4, 148, .{});

        w4.DRAW_COLORS.* = 0x1;
        w4.text("D", 10 * 12 + 4, 148);

        w4.DRAW_COLORS.* = 0x10;
        w4.rect(self.selection * 12 + 2, 146, 12, 12);

        const mouse = MouseState.get();
        if (mouse.buttons.left) {
            if (mouse.y > 142) {
                const button: u8 = @intCast(@divFloor(mouse.x - 2, 12));
                if (button < 10) {
                    self.selection = button;
                } else if (button == 10 and !prev_mouse.buttons.left) {
                    w4.trace(&self.level.asBase64());
                }
            } else {
                if (self.selection < 8) {
                    self.level.setTile(
                        @intCast(@divFloor(mouse.x, 8)),
                        @intCast(@divFloor(mouse.y, 8)),
                        Tile.fromTag(@enumFromInt(self.selection)),
                    );
                } else if (self.selection == 8) {
                    self.level.player.pos = mouse.x + mouse.y * 160;
                    self.level.player.snapX();
                    self.level.player.snapY();
                } else {
                    // TODO: Enemies
                }
            }
        }
        const gamepad = GamepadState.get(0);
        if (gamepad.right) {}
    }
};
