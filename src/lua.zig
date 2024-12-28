const std = @import("std");
const assert = std.debug.assert;
const ziglua = @import("ziglua");

const ZLua = ziglua.Lua;

pub const Lua = struct {
    const LuaUserData = struct {
        allocator: std.mem.Allocator,
        registeredTypes: std.StringArrayHashMap([:0]const u8) = undefined,

        fn init(_allocator: std.mem.Allocator) LuaUserData {
            return LuaUserData{
                .allocator = _allocator,
                .registeredTypes = std.StringArrayHashMap([:0]const u8).init(_allocator),
            };
        }

        fn destroy(self: *LuaUserData) void {
            self.registeredTypes.clearAndFree();
        }
    };

    pub inline fn inner(self: *Lua) *ZLua {
        return @ptrCast(self);
    }

    pub fn init(allocator: std.mem.Allocator) !*Lua {
        const ud = try allocator.create(LuaUserData);
        ud.* = LuaUserData.init(allocator);

        const lua: *Lua = @ptrCast(try ZLua.init(allocator));

        lua.setRegistry("LuaUserData", ud);

        return lua;
    }

    /// Reference to the book keeping struct used by the library.
    fn library_user_data(self: *Lua) *LuaUserData {
        return self.getRegistry(*LuaUserData, "LuaUserData") catch {
            @panic("Library user data was not set!");
        };
    }

    pub fn deinit(self: *Lua) void {
        _ = self;

        // const userdata = self.library_user_data();

        // _ = userdata;

        // var allocator = userdata.allocator;
        // allocator.destroy(userdata);

        // self.inner().deinit();
    }

    pub fn openLibs(self: *Lua) void {
        self.inner().openLibs();
    }

    pub fn injectPrettyPrint(self: *Lua) void {
        const cmd =
            \\-- Print contents of `tbl`, with indentation.
            \\-- `indent` sets the initial level of indentation.
            \\function pretty_print (tbl, indent)
            \\  if not indent then indent = 0 end
            \\  for k, v in pairs(tbl) do
            \\    formatting = string.rep("  ", indent) .. k .. ": "
            \\    if type(v) == "table" then
            \\      print(formatting)
            \\      pretty_print(v, indent+1)
            \\    elseif type(v) == 'boolean' then
            \\      print(formatting .. tostring(v))      
            \\    else
            \\      print(formatting .. v)
            \\    end
            \\  end
            \\end
        ;
        self.run(cmd) catch @panic("injectPrettyPrint failed");
    }

    pub fn run(self: *Lua, script: [:0]const u8) !void {
        try self.inner().doString(script);
    }

    pub fn set(self: *Lua, name: [:0]const u8, value: anytype) void {
        self.push(value);
        self.inner().setGlobal(name);
    }

    pub fn get(self: *Lua, comptime T: type, name: [:0]const u8) !T {
        if (try self.inner().getGlobal(name) != ziglua.LuaType.nil) {
            return try self.pop(T);
        } else {
            return error.invalid;
        }
    }

    pub fn getResource(self: *Lua, comptime T: type, name: [:0]const u8) !T {
        if (try self.inner().getGlobal(name) != ziglua.LuaType.nil) {
            return try self.popResource(T);
        } else {
            return error.invalid;
        }
    }

    pub fn setRegistry(self: *Lua, key: anytype, value: anytype) void {
        self.push(key);
        self.push(value);
        self.inner().rawSetTable(ziglua.registry_index);
    }

    pub fn getRegistry(self: *Lua, comptime T: type, key: anytype) !*T {
        self.push(key);
        _ = self.inner().rawGetTable(ziglua.registry_index);
        return self.inner().toUserdata(T, -1);
    }

    /// Creates a new table in the Lua registry (not on the stack).
    pub fn createTable(self: *Lua) !Lua.Table {
        self.inner().newTable();
        return try self.popResource(Lua.Table);
    }

    /// Creates a new meta table in the Lua registry (not on the stack).
    pub fn createMetaTable(self: *Lua, name: [:0]const u8) !Lua.Table {
        try self.inner().newMetatable(name);
        return try self.popResource(Lua.Table);
    }

    pub fn upvalueIndex(self: *Lua, comptime T: type, index: i32) !T {
        self.inner().upvalueIndex(index);
        return try self.pop(T);
    }

    pub fn createUserType(self: *Lua, comptime T: type, params: anytype) !Ref(T) {
        _ = self;
        _ = params;
        @panic("TODO");
        // var metaTableName: []const u8 = undefined;
        // // Allocate memory
        // var ptr = @ptrCast(*T, @alignCast(@alignOf(T), lualib.lua_newuserdata(self.L, @sizeOf(T))));
        // // set its metatable
        // if (getUserData(self.L).registeredTypes.get(@typeName(T))) |name| {
        //     metaTableName = name;
        // } else {
        //     return error.unregistered_type;
        // }
        // _ = lualib.luaL_getmetatable(self.L, @ptrCast([*c]const u8, metaTableName[0..]));
        // _ = lualib.lua_setmetatable(self.L, -2);
        // // (3) init & copy wrapped object
        // // Call init
        // const ArgTypes = std.meta.ArgsTuple(@TypeOf(T.init));
        // var args: ArgTypes = undefined;
        // const fields_info = std.meta.fields(@TypeOf(params));
        // const len = args.len;
        // comptime var idx = 0;
        // inline while (idx < len) : (idx += 1) {
        //     args[idx] = @field(params, fields_info[idx].name);
        // }
        // ptr.* = @call(.auto, T.init, args);
        // // (4) check and store the callback table
        // //_ = lua.luaL_checktype(L, 1, lua.LUA_TTABLE);
        // _ = lualib.lua_pushvalue(self.L, 1);
        // _ = lualib.lua_setuservalue(self.L, -2);
        // var res = try popResource(Ref(T), self.L);
        // res.ptr = ptr;
        // return res;
    }

    pub fn release(self: *Lua, v: anytype) void {
        _ = allocateDeallocateHelper(@TypeOf(v), true, self.library_user_data().allocator, v);
    }

    // Zig 0.10.0+ returns a fully qualified struct name, so require an explicit UserType name
    pub fn newUserType(self: *Lua, comptime T: type, comptime metaTableName: [:0]const u8) !void {
        // _ = self;
        // _ = T;
        // _ = name;

        comptime var hasInit: bool = false;
        comptime var hasDestroy: bool = false;
        //var metaTblName: [1024:0]u8 = undefined;
        //_ = comptime try std.fmt.bufPrintZ(&metaTblName, "{s}", .{name});
        // Init Lua states

        const allocFuns = comptime struct {
            fn new(zlua: *ZLua) !i32 {
                //
                const lua: *Lua = @ptrCast(zlua);

                var userdata = lua.inner().newUserdata(T);
                _ = lua.inner().getMetatableRegistry(metaTableName);
                lua.inner().setMetatable(-2);

                //comptime @compileLog(@TypeOf(T.init));

                try lua.pushZigFunction(@TypeOf(T.init), T.init);
                lua.inner().call(.{});
                userdata = lua.inner().toUserdata(T, -1) catch unreachable;

                return 1;
            }

            fn gc(zlua: *ZLua) !i32 {
                const lua: *Lua = @ptrCast(zlua);

                _ = lua;
                return 0;
            }
        };

        // comptime var allocFuns = struct {
        //     fn new(L: ?*ZLua) callconv(.C) c_int {
        //         // (1) get arguments
        //         var caller = FunctionWrapper(@TypeOf(T.init)).LowLevelHelpers.init();
        //         caller.prepareArgs(L) catch unreachable;

        //         // (2) create Lua object
        //         var ptr = @ptrCast(*T, @alignCast(@alignOf(T), lualib.lua_newuserdata(L, @sizeOf(T))));
        //         // set its metatable
        //         _ = lualib.luaL_getmetatable(L, @ptrCast([*c]const u8, metaTblName[0..]));
        //         _ = lualib.lua_setmetatable(L, -2);
        //         // (3) init & copy wrapped object
        //         caller.call(T.init) catch unreachable;
        //         ptr.* = caller.result;
        //         // (4) check and store the callback table
        //         //_ = lua.luaL_checktype(L, 1, lua.LUA_TTABLE);
        //         _ = lualib.lua_pushvalue(L, 1);
        //         _ = lualib.lua_setuservalue(L, -2);

        //         return 1;
        //     }

        //     fn gc(L: ?*ZLua) callconv(.C) c_int {
        //         var ptr = @ptrCast(*T, @alignCast(@alignOf(T), lualib.luaL_checkudata(L, 1, @ptrCast([*c]const u8, metaTblName[0..]))));
        //         ptr.destroy();
        //         return 0;
        //     }
        // };
        // // Create metatable

        const metatable = try self.createMetaTable(metaTableName);

        // self.L.newMetatable(metaTblName);

        // self.L.pushValue(-1);
        // self.L.setField(-1, "__index");

        metatable.set("__index", metatable);
        //metatable.set("__gc", allocFuns.gc);

        // _ = lualib.luaL_newmetatable(self.L, @ptrCast([*c]const u8, metaTblName[0..]));
        // // Metatable.__index = metatable
        // lualib.lua_pushvalue(self.L, -1);
        // lualib.lua_setfield(self.L, -2, "__index");

        // self.L.pushFunction(allocFuns.gc);
        // self.L.setField(-2, "__gc");

        // lualib.lua_pushcclosure(self.L, allocFuns.gc, 0);
        // lualib.lua_setfield(self.L, -2, "__gc");

        // // Collect information
        switch (@typeInfo(T)) {
            .@"struct" => |StructInfo| {
                inline for (StructInfo.decls) |decl| {
                    if (comptime std.mem.eql(u8, decl.name, "init") == true) {
                        hasInit = true;
                    } else if (comptime std.mem.eql(u8, decl.name, "destroy") == true) {
                        hasDestroy = true;
                    } else {
                        const field = comptime @field(T, decl.name);

                        try self.pushZigFunction(@TypeOf(field), field);
                        self.inner().setField(-2, decl.name);
                    }
                }
            },
            else => @compileError("Only Struct supported."),
        }
        if ((hasInit == false) or (hasDestroy == false)) {
            @compileError("Struct has to have init and destroy methods.");
        }
        // // Only the 'new' function
        // // <==_ = lua.luaL_newlib(lua.L, &arraylib_f); ==>
        // lualib.luaL_checkversion(self.L);
        // lualib.lua_createtable(self.L, 0, 1);
        // // lua.luaL_setfuncs(self.L, &funcs, 0); =>
        // lualib.lua_pushcclosure(self.L, allocFuns.new, 0);
        // lualib.lua_setfield(self.L, -2, "new");

        const globalTable = try self.createTable();

        //self.L.setField(-2, "new");

        globalTable.set("new", ziglua.wrap(allocFuns.new));

        self.set(metaTableName, globalTable);

        // // Set as global ('require' requires luaopen_{libraname} named static C functionsa and we don't want to provide one)
        // _ = lualib.lua_setglobal(self.L, @ptrCast([*c]const u8, metaTblName[0..]));

        // // Store in the registry

        try self.getUserData().registeredTypes.put(@typeName(T), metaTableName);
    }

    pub fn Function(comptime T: type) type {
        const FuncType = T;
        const RetType = blk: {
            const FuncInfo = @typeInfo(FuncType);
            if (FuncInfo == .pointer) {
                const PointerInfo = @typeInfo(FuncInfo.pointer.child);
                if (PointerInfo == .@"fn") {
                    break :blk PointerInfo.@"fn".return_type;
                }
            }

            @compileError("Unsupported type. " ++ @typeName(FuncType));
        };
        return struct {
            const Self = @This();

            lua: *Lua,
            ref: c_int = undefined,
            func: FuncType = undefined,

            // This 'Init' assumes, that the top element of the stack is a Lua function
            pub fn init(lua: *Lua) Self {
                const _ref = lua.inner().ref(ziglua.registry_index) catch {
                    @panic("The top element of the stack should be a Lua function");
                };

                const res = Self{
                    .lua = lua,
                    .ref = _ref,
                };
                return res;
            }

            pub fn destroy(self: *const Self) void {
                self.lua.inner().unref(ziglua.registry_index, self.ref);
            }

            pub fn call(self: *const Self, args: anytype) !RetType.? {
                const ArgsType = @TypeOf(args);
                if (@typeInfo(ArgsType) != .@"struct") {
                    ("Expected tuple or struct argument, found " ++ @typeName(ArgsType));
                }
                // Getting function reference
                _ = self.lua.inner().rawGetIndex(ziglua.registry_index, self.ref);

                // Preparing arguments
                comptime var i = 0;
                const fields_info = std.meta.fields(ArgsType);
                inline while (i < fields_info.len) : (i += 1) {
                    self.lua.push(args[i]);
                }
                // Calculating retval count
                const retValCount = switch (@typeInfo(RetType.?)) {
                    .void => 0,
                    .@"struct" => |StructInfo| StructInfo.fields.len,
                    else => 1,
                };
                // Calling

                try self.lua.inner().protectedCall(.{
                    .args = fields_info.len,
                    .results = retValCount,
                    .msg_handler = 0,
                });

                // Getting return value(s)
                if (retValCount > 0) {
                    return self.lua.pop(RetType.?);
                }
            }
        };
    }

    pub const Table = struct {
        const Self = @This();

        lua: *Lua,
        ref: c_int = undefined,

        // This 'Init' assumes, that the top element of the stack is a Lua table
        pub fn init(lua: *Lua) Self {
            const _ref = lua.inner().ref(ziglua.registry_index) catch {
                @panic("The top element of the stack should be a Lua table");
            };
            const res = Self{
                .lua = lua,
                .ref = _ref,
            };
            return res;
        }

        pub fn destroy(self: *const Self) void {
            self.lua.inner().unref(ziglua.registry_index, self.ref);
        }

        pub fn clone(self: *const Self) Self {
            self.lua.inner().rawGetIndex(ziglua.registry_index, self.ref);
            return Self.init(self.L, self.allocator);
        }

        pub fn set(self: *const Self, key: anytype, value: anytype) void {
            // Getting table reference
            _ = self.lua.inner().rawGetIndex(ziglua.registry_index, self.ref);
            // Push key, value
            self.lua.push(key);
            self.lua.push(value);
            // Set
            self.lua.inner().setTable(-3);
        }

        pub fn get(self: *const Self, comptime T: type, key: anytype) !T {
            // Getting table by reference
            _ = self.lua.inner().rawGetIndex(ziglua.registry_index, self.ref);

            // Push key
            self.lua.push(key);
            // Get
            _ = self.lua.inner().getTable(-2);

            return try self.lua.pop(T);
        }

        pub fn getResource(self: *const Self, comptime T: type, key: anytype) !T {
            // Getting table reference
            _ = self.lua.inner().rawGetIndex(ziglua.registry_index, self.ref);

            // Push key
            self.lua.push(key);
            // Get
            _ = self.lua.inner().getTable(-2);

            return try self.lua.popResource(T);
        }
    };

    pub fn Ref(comptime T: type) type {
        return struct {
            const Self = @This();

            lua: *Lua,
            ref: c_int = undefined,
            ptr: *T = undefined,

            pub fn init(lua: *Lua) Self {
                const _ref = lua.inner().ref(ziglua.registry_index);

                const res = Self{
                    .lua = lua,
                    .ref = _ref,
                };
                return res;
            }

            pub fn destroy(self: *const Self) void {
                self.lua.inner().unref(ziglua.registry_index, self.ref);
            }

            pub fn clone(self: *const Self) Self {
                self.lua.inner().rawGetIndex(ziglua.registry_index, self.ref);

                var result = Self.init(self.lua);
                result.ptr = self.ptr;
                return result;
            }
        };
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////
    fn pushSlice(self: *Lua, comptime T: type, values: []const T) void {
        const table = self.createTable() catch @panic("could not push slice");

        for (values, 0..) |value, i| {
            table.set(i + 1, value);
        }

        table.destroy();
    }

    fn push(self: *Lua, value: anytype) void {
        const L = self.inner();

        const T = @TypeOf(value);
        switch (@typeInfo(T)) {
            .void => L.pushNil(),
            .bool => L.pushBoolean(value),
            .int, .comptime_int => L.pushInteger(@intCast(value)),
            .float, .comptime_float => L.pushNumber(value),
            .array => |info| {
                //_ = info;
                //L.pushAny(value) catch {};
                //pushSlice(info.child, L, );

                self.pushSlice(info.child, &value);
            },
            .pointer => |PointerInfo| switch (PointerInfo.size) {
                .Slice => {
                    if (PointerInfo.child == u8) {
                        //_ = lualib.lua_pushlstring(L, value.ptr, value.len);
                        _ = L.pushString(value);
                    } else {
                        @compileError("invalid type: '" ++ @typeName(T) ++ "'");
                    }
                },
                .One => {
                    switch (@typeInfo(PointerInfo.child)) {
                        .array => |childInfo| {
                            //std.debug.print("{p}\n", .{L});
                            //std.debug.print("{s}\n", .{value});

                            if (childInfo.child == u8) {
                                _ = L.pushString(value);
                                //_ = lualib.lua_pushstring(L, @ptrCast([*c]const u8, value));
                            } else {
                                @compileError("invalid type: '" ++ @typeName(T) ++ "'");
                            }
                        },
                        .@"struct" => {
                            //unreachable;

                            L.pushLightUserdata(value);
                        },
                        else => @compileError("Unexpected type: '" ++ @typeName(T) ++ "'"),
                    }
                },
                .Many => {
                    if (PointerInfo.child == u8) {
                        const casted: [*c]const u8 = value;

                        const len = std.mem.len(casted);

                        _ = L.pushString(value[0..len]);
                    } else {
                        @compileError("invalid type: '" ++ @typeName(T) ++ "'. Typeinfo: '" ++ @typeInfo(PointerInfo.child) ++ "'");
                    }
                },
                .C => {
                    if (PointerInfo.child == u8) {
                        //_ = L.pushStringZ(@as([:0]const u8, value));
                        //_ = lualib.lua_pushstring(L, value);
                        const casted: [*c]const u8 = value;

                        const len = std.mem.len(casted);

                        //std.mem.
                        _ = L.pushString(value[0..len]);
                    } else {
                        @compileError("invalid type: '" ++ @typeName(T) ++ "'");
                    }
                },
            },
            .@"fn" => {
                // Possibly combine these first two args.
                try self.pushZigFunction(@TypeOf(value), value);
            },
            .@"struct" => |_| {
                const funIdx = comptime stringContains(@typeName(T), "Function");
                const tblIdx = comptime stringContains(@typeName(T), "Table");
                const refIdx = comptime stringContains(@typeName(T), "Ref");

                if (funIdx or tblIdx or refIdx) {
                    _ = L.rawGetIndex(ziglua.registry_index, value.ref);
                } else {
                    //L.pushLightUserdata(value);

                    var buf: [1024:0]u8 = undefined;
                    _ = std.fmt.bufPrintZ(&buf, "{}", .{value}) catch unreachable;

                    @panic(&buf);

                    //_ = L.rawGetIndex(ziglua.registry_index, value.ref);
                    //@compileError(&buf);
                    //@compileError("Only Function and Lua.Tables are supported; not '" ++ @typeName(T) ++ "'.");
                }
            },
            // .Type => {
            // },
            else => @compileError("Unsupported type: '" ++ @typeName(@TypeOf(value)) ++ "'"),
        }
    }

    fn pop(self: *Lua, comptime T: type) !T {
        defer self.inner().pop(1);

        const L = self.inner();

        switch (@typeInfo(T)) {
            .bool => {
                return L.toBoolean(-1);
            },
            .int, .comptime_int => {
                return @as(T, @intCast(try L.toInteger(-1)));
            },
            .float, .comptime_float => {
                return @as(T, @floatCast(try L.toNumber(-1)));
            },
            // Only string, allocless get (Lua holds the pointer, it is only a slice pointing to it)
            .pointer => |PointerInfo| switch (PointerInfo.size) {
                .Slice => {
                    // [] const u8 case
                    if (PointerInfo.child == u8 and PointerInfo.is_const) {
                        const result = L.toString(-1);
                        return result;
                    } else @compileError("Only '[]const u8' (aka string) is supported allocless.");
                },
                .One => {
                    const optionalTable = self.getUserData().registeredTypes.get(@typeName(PointerInfo.child));

                    //std.debug.print("{s}\n", .{@typeName(PointerInfo.child)});

                    if (optionalTable) |table| {
                        return L.checkUserdata(PointerInfo.child, -1, table);
                    } else {
                        return error.invalidType;
                    }
                    //return error.invalidType;

                    // std.debug.print("{s}\n", .{@typeName(PointerInfo.child)});

                    // std.debug.print("HERE7\n", .{});

                    // return L.checkUserdata(PointerInfo.child, -1, @typeName(PointerInfo.child));
                },
                else => @compileError("invalid type: '" ++ @typeName(T) ++ "'"),
            },
            .@"struct" => |StructInfo| {
                if (StructInfo.is_tuple) {
                    @compileError("Tuples are not supported.");
                }
                const funIdx = comptime stringContains(@typeName(T), "Function");
                const tblIdx = comptime stringContains(@typeName(T), "Table");
                if (funIdx >= 0 or tblIdx >= 0) {
                    @compileError("Only allocGet supports Lua.Function and Lua.Table. The type '" ++ @typeName(T) ++ "' is not supported.");
                }

                var result: T = .{ 0, 0 };
                comptime var i = 0;
                const fields_info = std.meta.fields(T);
                inline while (i < fields_info.len) : (i += 1) {
                    result[i] = pop(@TypeOf(result[i]), L);
                }
            },
            else => @compileError("invalid type: '" ++ @typeName(T) ++ "'"),
        }
    }

    fn popResource(self: *Lua, comptime T: type) !T {
        const L = self.inner();

        switch (@typeInfo(T)) {
            std.builtin.Type.pointer => |PointerInfo| switch (PointerInfo.size) {
                .Slice => {
                    defer L.pop(1);
                    if (L.typeOf(-1) == ziglua.LuaType.table) {
                        const len = self.inner().objectLen(-1);

                        var res = try L.allocator().alloc(PointerInfo.child, @intCast(len));
                        var i: u32 = 0;
                        while (i < len) : (i += 1) {
                            self.push(i + 1);
                            _ = L.getTable(-2);
                            res[i] = try self.pop(PointerInfo.child);
                        }
                        return res;
                    } else {
                        return error.bad_type;
                    }
                },
                else => @compileError("Only Slice is supported. Type: " ++ @typeName(T)),
            },
            std.builtin.Type.@"struct" => |_| {
                const funIdx = comptime stringContains(@typeName(T), "Function");
                const tblIdx = comptime stringContains(@typeName(T), "Table");
                const refIdx = comptime stringContains(@typeName(T), "Ref");

                if (funIdx) {
                    if (L.typeOf(-1) == ziglua.LuaType.function) {
                        return T.init(self);
                    } else {
                        defer L.pop(1);
                        return error.bad_type;
                    }
                } else if (tblIdx) {
                    if (L.typeOf(-1) == ziglua.LuaType.table) {
                        return T.init(self);
                    } else {
                        defer L.pop(1);
                        return error.bad_type;
                    }
                } else if (refIdx) {
                    if (L.typeOf(-1) == ziglua.LuaType.userdata) {
                        return T.init(L);
                    } else {
                        defer L.pop(1);
                        return error.bad_type;
                    }
                } else @compileError("Only Functions are supported; not '" ++ @typeName(T) ++ "'");
            },
            else => @compileError("invalid type: '" ++ @typeName(T) ++ "'"),
        }
    }

    fn stringContains(haystack: []const u8, needle: []const u8) bool {
        if (std.mem.indexOf(u8, haystack, needle)) |_| {
            return true;
        } else {
            return false;
        }
    }

    // It is a helper function, with two responsibilities:
    // 1. When it's called with only a type (allocator and value are both null) in compile time it returns that
    //    the given type is allocated or not
    // 2. When it's called with full arguments it cleans up.
    fn allocateDeallocateHelper(comptime T: type, comptime deallocate: bool, allocator: ?std.mem.Allocator, value: ?T) bool {
        switch (@typeInfo(T)) {
            .pointer => |PointerInfo| switch (PointerInfo.size) {
                .Slice => {
                    if (PointerInfo.child == u8 and PointerInfo.is_const) {
                        return false;
                    } else {
                        if (deallocate) {
                            allocator.?.free(value.?);
                        }
                        return true;
                    }
                },
                else => return false,
            },
            .@"struct" => |_| {
                const funIdx = comptime stringContains(@typeName(T), "Function");
                const tblIdx = comptime stringContains(@typeName(T), "Table");
                const refIdx = comptime stringContains(@typeName(T), "Ref");

                if (funIdx or tblIdx or refIdx) {
                    if (deallocate) {
                        value.?.destroy();
                    }
                    return true;
                } else return false;
            },
            else => {
                return false;
            },
        }
    }

    fn pushZigFunction(self: *Lua, comptime funcType: type, func: *const funcType) !void {
        const info = @typeInfo(funcType);
        if (info != .@"fn") {
            @compileError("pushZigFunction expects a function type");
        }

        const ReturnType = info.@"fn".return_type.?;
        const ArgTypes = comptime std.meta.ArgsTuple(funcType);
        const resultCnt = if (ReturnType == void) 0 else 1;

        const funcPtrAsInt = @as(c_longlong, @intCast(@intFromPtr(func)));

        const L = self.inner();

        L.pushInteger(funcPtrAsInt);

        const cfun = struct {
            fn helper(fn_zlua: *ZLua) !i32 {

                //std.debug.print("{s}\n", .{"before"});

                const fn_lua: *Lua = @ptrCast(fn_zlua);

                const _L = fn_lua.inner();

                var args: ArgTypes = undefined;

                // if (_L.getTop() <= args.len) {
                //     _L.raiseErrorStr("Not enough arguments supplied to function. Expected %d but received %d.", .{ args.len, _L.getTop() });
                // }

                // Maybe allocate arguments.
                inline for (0.., args) |i, arg| {
                    if (comptime allocateDeallocateHelper(@TypeOf(arg), false, null, null)) {
                        args[i] = try fn_lua.popResource(@TypeOf(arg));
                    } else {
                        args[i] = try fn_lua.pop(@TypeOf(arg));
                    }
                }
                // Get func pointer upvalue as int => convert to func ptr then call
                const ptr: usize = @intCast(try _L.toInteger(ZLua.upvalueIndex(1)));

                const result = @call(.auto, @as(*const funcType, @ptrFromInt(ptr)), args);

                if (resultCnt > 0) {
                    fn_lua.push(result);
                }

                // Deallocate any allocated arguments.
                inline for (0.., args) |i, _| {
                    _ = allocateDeallocateHelper(@TypeOf(args[i]), true, _L.allocator(), args[i]);
                }
                _ = allocateDeallocateHelper(ReturnType, true, _L.allocator(), result);

                return resultCnt;
            }
        }.helper;

        L.pushClosure(ziglua.wrap(cfun), 1);
    }

    fn getUserData(self: *Lua) *Lua.LuaUserData {
        return self.getRegistry(LuaUserData, "LuaUserData") catch {
            @panic("Library user data was not set!");
        };
    }

    fn getAllocator(self: *Lua) std.mem.Allocator {
        return self.getUserData().allocator();
    }
};

const TestCustomType = struct {
    a: i32,
    b: f32,
    c: []const u8,
    d: bool,

    pub fn init(_a: i32, _b: f32, _c: []const u8, _d: bool) TestCustomType {
        return TestCustomType{
            .a = _a,
            .b = _b,
            .c = _c,
            .d = _d,
        };
    }

    pub fn destroy(_: *TestCustomType) void {}

    pub fn getA(self: *TestCustomType) i32 {
        return self.a;
    }

    pub fn getB(self: *TestCustomType) f32 {
        return self.b;
    }

    pub fn getC(self: *TestCustomType) []const u8 {
        return self.c;
    }

    pub fn getD(self: *TestCustomType) bool {
        return self.d;
    }

    pub fn reset(self: *TestCustomType) void {
        self.a = 0;
        self.b = 0;
        self.c = "";
        self.d = false;
    }

    pub fn store(self: *TestCustomType, _a: i32, _b: f32, _c: []const u8, _d: bool) void {
        self.a = _a;
        self.b = _b;
        self.c = _c;
        self.d = _d;
    }
};

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var lua = try Lua.init(gpa.allocator());
    defer lua.deinit();
    lua.openLibs();

    lua.newUserType(TestCustomType, "TestCustomType") catch {
        std.debug.print("{s}\n", .{lua.inner().toString(-1) catch "Unknown"});
    };

    const tbl = try lua.createTable();
    defer tbl.destroy();

    tbl.set("welcome", "All your codebase are belong to us.");
    lua.set("zig", tbl);

    try lua.run("print(zig.welcome)");

    const func = struct {
        fn func(x: i32) i32 {
            return x + 1;
        }
    }.func;

    lua.set("func", func);

    lua.run("print(func(1))") catch {
        std.debug.print("{s}\n", .{lua.inner().toString(-1) catch "Unknown"});
    };

    //const function = try lua.get(Lua.Function(fn (x: i32) i32), "func");
    //function.call(.{42});

    // _a: i32, _b: f32, _c: []const u8, _d: bool
    lua.run("print(TestCustomType.new(1, 2, \"test\", false))") catch {
        std.debug.print("{s}\n", .{lua.inner().toString(-1) catch "Unknown"});
    };
}
