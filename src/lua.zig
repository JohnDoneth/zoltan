const std = @import("std");
const assert = std.debug.assert;
const ziglua = @import("ziglua");

const ZLua = ziglua.Lua;

pub const Lua = struct {
    const LuaUserData = struct {
        allocator: std.mem.Allocator,
        registeredTypes: std.StringArrayHashMap([]const u8) = undefined,

        fn init(_allocator: std.mem.Allocator) LuaUserData {
            return LuaUserData{ .allocator = _allocator, .registeredTypes = std.StringArrayHashMap([]const u8).init(_allocator) };
        }

        fn destroy(self: *LuaUserData) void {
            self.registeredTypes.clearAndFree();
        }
    };

    L: *ZLua,
    ud: *LuaUserData,

    pub fn init(allocator: std.mem.Allocator) !Lua {
        const _ud = try allocator.create(LuaUserData);
        _ud.* = LuaUserData.init(allocator);

        const lua = try ZLua.init(allocator);

        return .{
            .L = lua,
            .ud = _ud,
        };
    }

    pub fn destroy(self: *Lua) void {
        self.L.deinit();

        var allocator = self.ud.allocator;
        allocator.destroy(self.ud);
    }

    pub fn openLibs(self: *Lua) void {
        self.L.openLibs();
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
        try self.L.doString(script);
    }

    pub fn set(self: *Lua, name: [:0]const u8, value: anytype) void {
        Lua.push(self.L, value);
        self.L.setGlobal(name);
    }

    pub fn get(self: *Lua, comptime T: type, name: [:0]const u8) !T {
        if (try self.L.getGlobal(name) != ziglua.LuaType.nil) {
            return try pop(T, self.L);
        } else {
            return error.invalid;
        }
    }

    pub fn getResource(self: *Lua, comptime T: type, name: [:0]const u8) !T {
        if (try self.L.getGlobal(name) != ziglua.LuaType.nil) {
            return try popResource(T, self.L);
        } else {
            return error.invalid;
        }
    }

    pub fn createTable(self: *Lua) !Lua.Table {
        self.L.newTable();
        return try popResource(Lua.Table, self.L);
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
        _ = allocateDeallocateHelper(@TypeOf(v), true, self.ud.allocator, v);
    }

    // Zig 0.10.0+ returns a fully qualified struct name, so require an explicit UserType name
    pub fn newUserType(self: *Lua, comptime T: type, comptime name: []const u8) !void {
        _ = self;
        _ = T;
        _ = name;

        // comptime var hasInit: bool = false;
        // comptime var hasDestroy: bool = false;
        // comptime var metaTblName: [1024]u8 = undefined;
        // _ = comptime try std.fmt.bufPrint(metaTblName[0..], "{s}", .{name});
        // // Init Lua states
        // comptime var allocFuns = struct {
        //     fn new(L: ?*ZLua) callconv(.C) c_int {
        //         // (1) get arguments
        //         var caller = ZigCallHelper(@TypeOf(T.init)).LowLevelHelpers.init();
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
        // _ = lualib.luaL_newmetatable(self.L, @ptrCast([*c]const u8, metaTblName[0..]));
        // // Metatable.__index = metatable
        // lualib.lua_pushvalue(self.L, -1);
        // lualib.lua_setfield(self.L, -2, "__index");

        // //lua.luaL_setfuncs(self.L, &methods, 0); =>
        // lualib.lua_pushcclosure(self.L, allocFuns.gc, 0);
        // lualib.lua_setfield(self.L, -2, "__gc");

        // // Collect information
        // switch (@typeInfo(T)) {
        //     .Struct => |StructInfo| {
        //         inline for (StructInfo.decls) |decl| {
        //             if (comptime std.mem.eql(u8, decl.name, "init") == true) {
        //                 hasInit = true;
        //             } else if (comptime std.mem.eql(u8, decl.name, "destroy") == true) {
        //                 hasDestroy = true;
        //             } else if (decl.is_pub) {
        //                 comptime var field = @field(T, decl.name);
        //                 const Caller = ZigCallHelper(@TypeOf(field));
        //                 Caller.pushFunctor(self.L, field) catch unreachable;
        //                 lualib.lua_setfield(self.L, -2, @ptrCast([*c]const u8, decl.name));
        //             }
        //         }
        //     },
        //     else => @compileError("Only Struct supported."),
        // }
        // if ((hasInit == false) or (hasDestroy == false)) {
        //     @compileError("Struct has to have init and destroy methods.");
        // }
        // // Only the 'new' function
        // // <==_ = lua.luaL_newlib(lua.L, &arraylib_f); ==>
        // lualib.luaL_checkversion(self.L);
        // lualib.lua_createtable(self.L, 0, 1);
        // // lua.luaL_setfuncs(self.L, &funcs, 0); =>
        // lualib.lua_pushcclosure(self.L, allocFuns.new, 0);
        // lualib.lua_setfield(self.L, -2, "new");

        // // Set as global ('require' requires luaopen_{libraname} named static C functionsa and we don't want to provide one)
        // _ = lualib.lua_setglobal(self.L, @ptrCast([*c]const u8, metaTblName[0..]));

        // // Store in the registry
        // try getUserData(self.L).registeredTypes.put(@typeName(T), metaTblName[0..]);
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

            @compileError("Unsupported type");
        };
        return struct {
            const Self = @This();

            L: *ZLua,
            ref: c_int = undefined,
            func: FuncType = undefined,

            // This 'Init' assumes, that the top element of the stack is a Lua function
            pub fn init(_L: *ZLua) Self {
                const _ref = _L.ref(ziglua.registry_index) catch {
                    @panic("The top element of the stack should be a Lua function");
                };

                const res = Self{
                    .L = _L,
                    .ref = _ref,
                };
                return res;
            }

            pub fn destroy(self: *const Self) void {
                Lua.unref(self.ref);
            }

            pub fn call(self: *const Self, args: anytype) !RetType.? {
                const ArgsType = @TypeOf(args);
                if (@typeInfo(ArgsType) != .@"struct") {
                    ("Expected tuple or struct argument, found " ++ @typeName(ArgsType));
                }
                // Getting function reference
                _ = self.L.rawGetIndex(ziglua.registry_index, self.ref);

                // Preparing arguments
                comptime var i = 0;
                const fields_info = std.meta.fields(ArgsType);
                inline while (i < fields_info.len) : (i += 1) {
                    Lua.push(self.L, args[i]);
                }
                // Calculating retval count
                const retValCount = switch (@typeInfo(RetType.?)) {
                    .void => 0,
                    .@"struct" => |StructInfo| StructInfo.fields.len,
                    else => 1,
                };
                // Calling

                try self.L.protectedCall(.{
                    .args = fields_info.len,
                    .results = retValCount,
                    .msg_handler = 0,
                });

                // Getting return value(s)
                if (retValCount > 0) {
                    return Lua.pop(RetType.?, self.L);
                }
            }
        };
    }

    pub const Table = struct {
        const Self = @This();

        L: *ZLua,
        ref: c_int = undefined,

        // This 'Init' assumes, that the top element of the stack is a Lua table
        pub fn init(_L: *ZLua) Self {
            const _ref = _L.ref(ziglua.registry_index) catch {
                @panic("The top element of the stack should be a Lua table");
            };
            const res = Self{
                .L = _L,
                .ref = _ref,
            };
            return res;
        }

        // Unregister this shit
        pub fn destroy(self: *const Self) void {
            self.L.unref(ziglua.registry_index, self.ref);
        }

        pub fn clone(self: *const Self) Self {
            self.L.rawGetIndex(ziglua.registry_index, self.ref);
            return Table.init(self.L, self.allocator);
        }

        pub fn set(self: *const Self, key: anytype, value: anytype) void {
            // Getting table reference
            _ = self.L.rawGetIndex(ziglua.registry_index, self.ref);
            // Push key, value
            Lua.push(self.L, key);
            Lua.push(self.L, value);
            // Set
            self.L.setTable(-3);
        }

        pub fn get(self: *const Self, comptime T: type, key: anytype) !T {
            // Getting table by reference
            _ = self.L.rawGetIndex(ziglua.registry_index, self.ref);

            // Push key
            Lua.push(self.L, key);
            // Get
            _ = self.L.getTable(-2);

            return try Lua.pop(T, self.L);
        }

        pub fn getResource(self: *const Self, comptime T: type, key: anytype) !T {
            // Getting table reference
            _ = self.L.rawGetIndex(ziglua.registry_index, self.ref);

            // Push key
            Lua.push(self.L, key);
            // Get
            _ = self.L.getTable(-2);

            return try Lua.popResource(T, self.L);
        }
    };

    pub fn Ref(comptime T: type) type {
        return struct {
            const Self = @This();

            L: *ZLua,
            ref: c_int = undefined,
            ptr: *T = undefined,

            pub fn init(_L: *ZLua) Self {
                const _ref = _L.ref(ziglua.registry_index);

                const res = Self{
                    .L = _L,
                    .ref = _ref,
                };
                return res;
            }

            pub fn destroy(self: *const Self) void {
                ZLua.unref(self.ref);
            }

            pub fn clone(self: *const Self) Self {
                self.L.rawGetIndex(ziglua.registry_index, self.ref);

                var result = Self.init(self.L);
                result.ptr = self.ptr;
                return result;
            }
        };
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////
    fn pushSlice(comptime T: type, L: *ZLua, values: []const T) void {
        L.createTable(@intCast(values.len), 0);

        for (values, 0..) |value, i| {
            push(L, i + 1);
            push(L, value);

            L.setTable(-3);
        }
    }

    fn push(L: *ZLua, value: anytype) void {
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

                pushSlice(info.child, L, &value);
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
                            if (childInfo.child == u8) {
                                _ = L.pushString(value);
                                //_ = lualib.lua_pushstring(L, @ptrCast([*c]const u8, value));
                            } else {
                                @compileError("invalid type: '" ++ @typeName(T) ++ "'");
                            }
                        },
                        .@"struct" => {
                            unreachable;
                        },
                        else => @compileError("Unexpected type"),
                    }
                },
                .Many => {
                    if (PointerInfo.child == u8) {
                        //_ = lualib.lua_pushstring(L, @ptrCast([*c]const u8, value));
                        //_ = L.pushString(value);

                        // const null_terminated = try L.allocator().dupeZ(u8, value);
                        // defer L.allocator().free(null_terminated);

                        const casted: [*c]const u8 = value;

                        const len = std.mem.len(casted);

                        //std.mem.
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
                try FunctionWrapper(@TypeOf(value), value, L);
            },
            .@"struct" => |_| {
                const funIdx = comptime indexOfNullable(T, "Function");
                const tblIdx = comptime indexOfNullable(T, "Table");
                const refIdx = comptime indexOfNullable(T, "Ref");

                if (funIdx >= 0 or tblIdx >= 0 or refIdx >= 0) {
                    _ = L.rawGetIndex(ziglua.registry_index, value.ref);
                } else {
                    @compileError("Only Function and Lua.Tables are supported; not '" ++ @typeName(T) ++ "'.");
                }
            },
            // .Type => {
            // },
            else => @compileError("Unsupported type: '" ++ @typeName(@TypeOf(value)) ++ "'"),
        }
    }

    fn pop(comptime T: type, L: *ZLua) !T {
        defer L.pop(1);

        switch (@typeInfo(T)) {
            .bool => {
                return L.toBoolean(-1);
            },
            .int, .comptime_int => {
                //var isnum: i32 = 0;
                const result: T = @as(T, @intCast(try L.toInteger(-1)));
                return result;
            },
            .float, .comptime_float => {
                //var isnum: i32 = 0;
                const result: T = @as(T, @floatCast(try L.toNumber(-1)));
                return result;
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
                    @panic("TODO");
                    // var optionalTbl = getUserData(L).registeredTypes.get(@typeName(PointerInfo.child));
                    // if (optionalTbl) |tbl| {
                    //     @panic("TODO");
                    //     //var result: T = @as(T, @ptrCast(@alignCast(@alignOf(PointerInfo.child), lualib.luaL_checkudata(L, -1, @ptrCast([*c]const u8, tbl[0..])))));
                    //     //return result;
                    // } else {
                    //     return error.invalidType;
                    // }
                },
                else => @compileError("invalid type: '" ++ @typeName(T) ++ "'"),
            },
            .@"struct" => |StructInfo| {
                if (StructInfo.is_tuple) {
                    @compileError("Tuples are not supported.");
                }
                const funIdx = comptime indexOfNullable(T, "Function");
                const tblIdx = comptime indexOfNullable(T, "Table");
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

    fn indexOfNullable(comptime T: type, needle: []const u8) i32 {
        if (std.mem.indexOf(u8, @typeName(T), needle)) |value| {
            return @intCast(value);
        } else {
            return -1;
        }
    }

    fn popResource(comptime T: type, L: *ZLua) !T {
        switch (@typeInfo(T)) {
            std.builtin.Type.pointer => |PointerInfo| switch (PointerInfo.size) {
                .Slice => {
                    defer L.pop(1);
                    if (L.typeOf(-1) == ziglua.LuaType.table) {
                        L.len(-1);
                        const len = try pop(u64, L);
                        var res = try L.allocator().alloc(PointerInfo.child, @intCast(len));
                        var i: u32 = 0;
                        while (i < len) : (i += 1) {
                            push(L, i + 1);
                            _ = L.getTable(-2);
                            res[i] = try Lua.pop(PointerInfo.child, L);
                        }
                        return res;
                    } else {
                        return error.bad_type;
                    }
                },
                else => @compileError("Only Slice is supported. Type: " ++ @typeName(T)),
            },
            std.builtin.Type.@"struct" => |_| {
                const funIdx = comptime indexOfNullable(T, "Function");
                const tblIdx = comptime indexOfNullable(T, "Table");
                const refIdx = comptime indexOfNullable(T, "Ref");

                if (funIdx >= 0) {
                    if (L.typeOf(-1) == ziglua.LuaType.function) {
                        return T.init(L);
                    } else {
                        defer L.pop(1);
                        return error.bad_type;
                    }
                } else if (tblIdx >= 0) {
                    if (L.typeOf(-1) == ziglua.LuaType.table) {
                        return T.init(L);
                    } else {
                        defer L.pop(1);
                        return error.bad_type;
                    }
                } else if (refIdx >= 0) {
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
                const funIdx = comptime indexOfNullable(T, "Function");
                const tblIdx = comptime indexOfNullable(T, "Table");
                const refIdx = comptime indexOfNullable(T, "Ref");

                if (funIdx >= 0 or tblIdx >= 0 or refIdx >= 0) {
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

    fn FunctionWrapper(comptime funcType: type, func: *const funcType, L: *ZLua) !void {
        const info = @typeInfo(funcType);
        if (info != .@"fn") {
            @compileError("FunctionWrapper expects a function type");
        }

        const ReturnType = info.@"fn".return_type.?;
        const ArgTypes = comptime std.meta.ArgsTuple(funcType);
        const resultCnt = if (ReturnType == void) 0 else 1;

        const funcPtrAsInt = @as(c_longlong, @intCast(@intFromPtr(func)));

        L.pushInteger(funcPtrAsInt);

        const cfun = struct {
            fn helper(_L: *ZLua) !i32 {
                //std.debug.print("{s}\n", .{"before"});

                var args: ArgTypes = undefined;

                if (_L.getTop() <= args.len) {
                    _L.raiseErrorStr("Not enough arguments supplied to function. Expected %d but received %d.", .{ args.len, _L.getTop() });
                }

                // Maybe allocate arguments.
                inline for (0.., args) |i, arg| {
                    if (comptime allocateDeallocateHelper(@TypeOf(arg), false, null, null)) {
                        args[i] = try popResource(@TypeOf(arg), _L);
                    } else {
                        args[i] = try pop(@TypeOf(arg), _L);
                    }
                }
                // Get func pointer upvalue as int => convert to func ptr then call
                const ptr: usize = @intCast(try _L.toInteger(ZLua.upvalueIndex(1)));

                const result = @call(.auto, @as(*const funcType, @ptrFromInt(ptr)), args);

                if (resultCnt > 0) {
                    push(_L, result);
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

    // fn ZigCallHelper(comptime funcType: type) type {
    //     const info = @typeInfo(funcType);
    //     if (info != .@"fn") {
    //         @compileError("ZigCallHelper expects a function type");
    //     }

    //     @compileLog(funcType);

    //     const ReturnType = info.@"fn".return_type.?;
    //     const ArgTypes = std.meta.ArgsTuple(funcType);
    //     const resultCnt = if (ReturnType == void) 0 else 1;

    //     return struct {
    //         pub const LowLevelHelpers = struct {
    //             const Self = @This();

    //             compargs: ArgTypes = undefined,
    //             result: ReturnType = undefined,

    //             pub fn init() Self {
    //                 return Self{};
    //             }

    //             fn prepareArgs(self: *Self, L: ?*ZLua) !void {

    //                 @compileLog("args");
    //                 inline for (self.args) |x| {
    //                     @compileLog(x);
    //                 }

    //                 // Prepare arguments
    //                 if (self.args.len <= 0) return;
    //                 var i: i32 = (self.args.len - 1);
    //                 inline while (i > -1) : (i -= 1) {
    //                     if (allocateDeallocateHelper(@TypeOf(self.args[i]), false, null, null)) {
    //                         self.args[i] = popResource(@TypeOf(self.args[i]), L.?) catch unreachable;
    //                     } else {
    //                         self.args[i] = pop(@TypeOf(self.args[i]), L.?) catch unreachable;
    //                     }
    //                 }
    //             }

    //             fn call(self: *Self, func: *const funcType) !void {
    //                 self.result = @call(.auto, func, self.args);
    //             }

    //             fn pushResult(self: *Self, L: ?*ZLua) !void {
    //                 if (resultCnt > 0) {
    //                     push(L.?, self.result);
    //                 }
    //             }

    //             fn destroyArgs(self: *Self, L: ?*ZLua) !void {
    //                 if (self.args.len <= 0) return;
    //                 var i: i32 = self.args.len - 1;
    //                 inline while (i > -1) : (i -= 1) {
    //                     _ = allocateDeallocateHelper(@TypeOf(self.args[i]), true, L.allocator(), self.args[i]);
    //                 }
    //                 _ = allocateDeallocateHelper(ReturnType, true, L.allocator(), self.result);
    //             }
    //         };

    //         pub fn pushFunctor(L: ?*ZLua, func: *const funcType) !void {
    //             const funcPtrAsInt = @as(c_longlong, @intCast(@intFromPtr(func)));

    //             L.?.pushInteger(funcPtrAsInt);

    //             const cfun = struct {
    //                 fn helper(_L: *ZLua) callconv(.C) c_int {

    //                     var f: LowLevelHelpers = undefined;
    //                     // Prepare arguments from stack
    //                     f.prepareArgs(_L) catch unreachable;
    //                     // Get func pointer upvalue as int => convert to func ptr then call

    //                     const ptr = _L.toInteger(ZLua.upvalueIndex(1)) catch unreachable;

    //                     f.call(@as(*const funcType, @ptrFromInt(ptr))) catch unreachable;
    //                     // The end
    //                     f.pushResult(_L) catch unreachable;
    //                     // Release arguments
    //                     f.destroyArgs(_L) catch unreachable;
    //                     return resultCnt;
    //                 }
    //             }.helper;

    //             L.?.pushClosure(ziglua.wrap(cfun), 1);
    //         }
    //     };
    // }

    fn getUserData(L: ?*ZLua) *Lua.LuaUserData {
        _ = L;
        //var ud: *anyopaque = undefined;

        //L.?.getAlloc( ud)
        //L.?.toUserdata(comptime T: type, index: i32)

        // return L.?.getAlloc(Lua.LuaUserData, "test");

        //_ = lualib.lua_getallocf(L, @ptrCast([*c]?*anyopaque, &ud));
        //const userData = @ptrCast(*Lua.LuaUserData, @alignCast(@alignOf(Lua.LuaUserData), ud));
        //return userData;
    }

    fn getAllocator(L: ?*ZLua) std.mem.Allocator {
        return getUserData(L).allocator;
    }

    //     // Credit: https://github.com/daurnimator/zig-autolua
    //     fn alloc(ud: ?*anyopaque, ptr: ?*anyopaque, osize: usize, nsize: usize) callconv(.C) ?*anyopaque {
    //         const c_alignment = 16;
    //         const userData = @ptrCast(*Lua.LuaUserData, @alignCast(@alignOf(Lua.LuaUserData), ud));
    //         if (@ptrCast(?[*]align(c_alignment) u8, @alignCast(c_alignment, ptr))) |previous_pointer| {
    //             const previous_slice = previous_pointer[0..osize];
    //             return (userData.allocator.realloc(previous_slice, nsize) catch return null).ptr;
    //         } else {
    //             // osize is any of LUA_TSTRING, LUA_TTABLE, LUA_TFUNCTION, LUA_TUSERDATA, or LUA_TTHREAD
    //             // when (and only when) Lua is creating a new object of that type.
    //             // When osize is some other value, Lua is allocating memory for something else.
    //             return (userData.allocator.alignedAlloc(u8, c_alignment, nsize) catch return null).ptr;
    //         }
    //     }
};

pub fn main() anyerror!void {
    var lua = try Lua.init(std.heap.c_allocator);
    defer lua.destroy();
    lua.openLibs();

    const tbl = try lua.createTable();
    defer lua.release(tbl);

    tbl.set("welcome", "All your codebase are belong to us.");
    lua.set("zig", tbl);

    try lua.run("print(zig.welcome)");

    const func = struct {
        fn func(x: i32) i32 {
            return x + 1;
        }
    }.func;

    lua.set("func", func);

    lua.run("print(func())") catch {
        std.debug.print("{s}\n", .{lua.L.toString(-1) catch "Unknown"});
    };
}
