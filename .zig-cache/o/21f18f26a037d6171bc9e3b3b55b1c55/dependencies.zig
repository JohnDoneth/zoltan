pub const packages = struct {
    pub const @"12203fe1feebb81635f8df5a5a7242733e441fe3f3043989c8e6b4d6720e96988813" = struct {
        pub const build_root = "/home/john/.cache/zig/p/12203fe1feebb81635f8df5a5a7242733e441fe3f3043989c8e6b4d6720e96988813";
        pub const deps: []const struct { []const u8, []const u8 } = &.{};
    };
    pub const @"12205923460670d52fb29fc74ec920d283dbe629a256787a54f4290748c05bee6ae1" = struct {
        pub const build_root = "/home/john/.cache/zig/p/12205923460670d52fb29fc74ec920d283dbe629a256787a54f4290748c05bee6ae1";
        pub const build_zig = @import("12205923460670d52fb29fc74ec920d283dbe629a256787a54f4290748c05bee6ae1");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
            .{ "lua51", "12203fe1feebb81635f8df5a5a7242733e441fe3f3043989c8e6b4d6720e96988813" },
            .{ "lua52", "1220d5b2b39738f0644d9ed5b7431973f1a16b937ef86d4cf85887ef3e9fda7a3379" },
            .{ "lua53", "1220937a223531ef6b3fea8f653dc135310b0e84805e7efa148870191f5ab915c828" },
            .{ "lua54", "12206df90729936e110f5d2574437be370fc4367b5f44afcc77749ac421547bc8ff0" },
            .{ "luajit", "1220ae2d84cfcc2a7aa670661491f21bbed102d335de18ce7d36866640fd9dfcc33a" },
            .{ "luau", "1220c76fb74b983b0ebfdd6b3a4aa8adf0c1ff69c9b6a9e9e05f9bc6a6c57a690e23" },
        };
    };
    pub const @"12206df90729936e110f5d2574437be370fc4367b5f44afcc77749ac421547bc8ff0" = struct {
        pub const build_root = "/home/john/.cache/zig/p/12206df90729936e110f5d2574437be370fc4367b5f44afcc77749ac421547bc8ff0";
        pub const deps: []const struct { []const u8, []const u8 } = &.{};
    };
    pub const @"1220937a223531ef6b3fea8f653dc135310b0e84805e7efa148870191f5ab915c828" = struct {
        pub const build_root = "/home/john/.cache/zig/p/1220937a223531ef6b3fea8f653dc135310b0e84805e7efa148870191f5ab915c828";
        pub const deps: []const struct { []const u8, []const u8 } = &.{};
    };
    pub const @"1220ae2d84cfcc2a7aa670661491f21bbed102d335de18ce7d36866640fd9dfcc33a" = struct {
        pub const build_root = "/home/john/.cache/zig/p/1220ae2d84cfcc2a7aa670661491f21bbed102d335de18ce7d36866640fd9dfcc33a";
        pub const deps: []const struct { []const u8, []const u8 } = &.{};
    };
    pub const @"1220c76fb74b983b0ebfdd6b3a4aa8adf0c1ff69c9b6a9e9e05f9bc6a6c57a690e23" = struct {
        pub const build_root = "/home/john/.cache/zig/p/1220c76fb74b983b0ebfdd6b3a4aa8adf0c1ff69c9b6a9e9e05f9bc6a6c57a690e23";
        pub const deps: []const struct { []const u8, []const u8 } = &.{};
    };
    pub const @"1220d5b2b39738f0644d9ed5b7431973f1a16b937ef86d4cf85887ef3e9fda7a3379" = struct {
        pub const build_root = "/home/john/.cache/zig/p/1220d5b2b39738f0644d9ed5b7431973f1a16b937ef86d4cf85887ef3e9fda7a3379";
        pub const deps: []const struct { []const u8, []const u8 } = &.{};
    };
};

pub const root_deps: []const struct { []const u8, []const u8 } = &.{
    .{ "ziglua", "12205923460670d52fb29fc74ec920d283dbe629a256787a54f4290748c05bee6ae1" },
};
