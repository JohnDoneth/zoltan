const std = @import("std");
const assert = std.debug.assert;

var luaAllocator: *std.mem.Allocator = undefined;

pub const lualib = @cImport({
    @cInclude("lua.h");
    @cInclude("lauxlib.h");
    @cInclude("lualib.h");
});

var registeredTypes: std.StringArrayHashMap([] const u8) = undefined;

const Lua = struct {
    L: *lualib.lua_State,
    allocator: *std.mem.Allocator,
    //registeredTypes: std.ArrayList(std.builtin.TypeInfo),
    //

    pub fn init(allocator: *std.mem.Allocator) !Lua {
        var _state = lualib.lua_newstate(alloc, allocator) orelse return error.OutOfMemory;
        luaAllocator = allocator;
        var state = Lua{
            .L = _state,
            .allocator = allocator,
            //.registeredTypes = std.StringArrayHashMap([] const u8).init(allocator),
        };
        registeredTypes = std.StringArrayHashMap([] const u8).init(allocator);
        return state;
    }

    pub fn destroy(self: *Lua) void {
        _ = lualib.lua_close(self.L);
    }

    pub fn openLibs(self: *Lua) void {
        _ = lualib.luaL_openlibs(self.L);
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
        self.run(cmd);
    }

    pub fn run(self: *Lua, script: []const u8) void {
        _ = lualib.luaL_loadstring(self.L, @ptrCast([*c]const u8, script));
        _ = lualib.lua_pcallk(self.L, 0, 0, 0, 0, null);
    }

    pub fn set(self: *Lua, name: []const u8, value: anytype) void {
        _ = push(self.L, value);
        _ = lualib.lua_setglobal(self.L, @ptrCast([*c]const u8, name));
    }

    pub fn get(self: *Lua, comptime T: type, name: []const u8) !T {
        const typ = lualib.lua_getglobal(self.L, @ptrCast([*c]const u8, name));
        if (typ != lualib.LUA_TNIL) {
            return try pop(T, self.L);
        } else {
            return error.novalue;
        }
    }

    pub fn getResource(self: *Lua, comptime T: type, name: []const u8) !T {
        const typ = lualib.lua_getglobal(self.L, @ptrCast([*c]const u8, name));
        if (typ != lualib.LUA_TNIL) {
            return try popResource(T, self.L, self.allocator);
        } else {
            return error.novalue;
        }
    }

    pub fn createTableResource(self: *Lua) !Lua.Table {
        _ = lualib.lua_createtable(self.L, 0, 0);
        return try popResource(Lua.Table, self.L, self.allocator);
    }

    pub fn release(self: *Lua, v: anytype) void {
        _ = allocateDeallocateHelper(@TypeOf(v), true, self.allocator, v);
    }
    
    pub fn newUserType(self: *Lua, comptime T: type) !void {
        comptime var hasInit: bool = false;
        comptime var hasDestroy: bool = false;
        comptime var metaTblName: [1024]u8 = undefined;
        _ = comptime try std.fmt.bufPrint(metaTblName[0..], "{s}", .{@typeName(T)});
        // Init Lua states
        comptime var allocFuns = struct {
            fn new(L: ?*lualib.lua_State) callconv(.C) c_int {
                // (1) get arguments
                var caller = ZigCallHelper(@TypeOf(T.init)).LowLevelHelpers.init();
                caller.prepareArgs(L) catch unreachable;

                // (2) create Lua object
                var ptr = @ptrCast(*T, @alignCast(@alignOf(T), lualib.lua_newuserdata(L, @sizeOf(T))));
                //std.log.info("new ptr: {d}", .{@ptrToInt(ptr)});
                // set its metatable
                _ = lualib.luaL_getmetatable(L, @ptrCast([*c]const u8, metaTblName[0..]));
                _ = lualib.lua_setmetatable(L, -2);
                // (3) init & copy wrapped object 
                caller.call(T.init) catch unreachable;
                ptr.* = caller.result;
                // (4) check and store the callback table
                //_ = lua.luaL_checktype(L, 1, lua.LUA_TTABLE);
                _ = lualib.lua_pushvalue(L, 1);
                _ = lualib.lua_setuservalue(L, -2);

                std.log.debug("'{s}' object is created.", .{metaTblName});
                return 1;
            }

            fn gc(L: ?*lualib.lua_State) callconv(.C) c_int {
                var ptr = @ptrCast(*T, @alignCast(@alignOf(T), lualib.luaL_checkudata(L, 1, @ptrCast([*c]const u8, metaTblName[0..]))));
                ptr.destroy();
                std.log.info("gc ptr: {d}", .{@ptrToInt(ptr)});
                return 0;
            }
        };
        std.log.info("Funs: {}/{}", .{ allocFuns.new, allocFuns.gc });
        // Create metatable
        _ = lualib.luaL_newmetatable(self.L, @ptrCast([*c]const u8, metaTblName[0..]));
        // Metatable.__index = metatable
        lualib.lua_pushvalue(self.L, -1);
        lualib.lua_setfield(self.L, -2, "__index");

        //lua.luaL_setfuncs(self.L, &methods, 0); =>
        lualib.lua_pushcclosure(self.L, allocFuns.gc, 0);
        lualib.lua_setfield(self.L, -2, "__gc");

        // Collect information
        switch (@typeInfo(T)) {
            .Struct => |StructInfo| {
                inline for (StructInfo.decls) |decl| {
                    switch (decl.data) {
                        .Fn => |FnInfo| {
                            if (comptime std.mem.eql(u8, decl.name, "init") == true) {
                                hasInit = true;
                            } else if (comptime std.mem.eql(u8, decl.name, "destroy") == true) {
                                hasDestroy = true;
                            } else if (decl.is_pub) {
                                comptime var field = @field(T, decl.name);
                                const Caller = ZigCallHelper(@TypeOf(field));
                                std.log.info("\t{s}: {s} at {}", .{ decl.name, @typeName(FnInfo.fn_type), @ptrToInt(field) });
                                const ArgsType = std.meta.ArgsTuple(FnInfo.fn_type);
                                var args: ArgsType = undefined;
                                std.log.info("\tRegistering method: {s}", .{@typeName(@TypeOf(args[0]))});
                                //std.log.info("\tBaszataska: {s}", .{@typeName(ArgsType.@"0")});
                                Caller.pushFunctor(self.L, field) catch unreachable;
                                lualib.lua_setfield(self.L, -2, @ptrCast([*c]const u8, decl.name));

                            }
                        },
                        else => {},
                    }
                }
            },
            else => @compileError("Only Struct supported."),
        }
        if ((hasInit == false) or (hasDestroy == false)) {
            @compileError("Struct has to have init and destroy methods.");
        }
        // Only the 'new' function
        // <==_ = lua.luaL_newlib(lua.L, &arraylib_f); ==>
        lualib.luaL_checkversion(self.L);
        lualib.lua_createtable(self.L, 0, 1);
        // lua.luaL_setfuncs(self.L, &funcs, 0); =>
        lualib.lua_pushcclosure(self.L, allocFuns.new, 0);
        lualib.lua_setfield(self.L, -2, "new");

        // Set as global ('require' requires luaopen_{libraname} named static C functionsa and we don't want to provide one)
        _ = lualib.lua_setglobal(self.L, @ptrCast([*c]const u8, metaTblName[0..]));

        // Store in the registry
        try registeredTypes.put(@typeName(T), metaTblName[0..]);
    }

    fn Function(comptime T: type) type {
        const FuncType = T;
        const RetType =
            switch (@typeInfo(FuncType)) {
            .Fn => |FunctionInfo| FunctionInfo.return_type,
            else => @compileError("Unsupported type."),
        };
        return struct {
            const Self = @This();

            L: *lualib.lua_State,
            allocator: *std.mem.Allocator,
            ref: c_int = undefined,
            func: FuncType = undefined,

            // This 'Init' assumes, that the top element of the stack is a Lua function
            fn init(_L: *lualib.lua_State, _allocator: *std.mem.Allocator) Self {
                const _ref = lualib.luaL_ref(_L, lualib.LUA_REGISTRYINDEX);
                var res = Self{
                    .L = _L,
                    .allocator = _allocator,
                    .ref = _ref,
                };
                return res;
            }

            fn destroy(self: *const Self) void {
                lualib.luaL_unref(self.L, lualib.LUA_REGISTRYINDEX, self.ref);
            }

            fn call(self: *const Self, args: anytype) !RetType.? {
                const ArgsType = @TypeOf(args);
                if (@typeInfo(ArgsType) != .Struct) {
                    ("Expected tuple or struct argument, found " ++ @typeName(ArgsType));
                }
                // Getting function reference
                _ = lualib.lua_rawgeti(self.L, lualib.LUA_REGISTRYINDEX, self.ref);
                // Preparing arguments
                comptime var i = 0;
                const fields_info = std.meta.fields(ArgsType);
                inline while (i < fields_info.len) : (i += 1) {
                    //std.log.info("Parameter: {}: {} ({s})", .{i, args[i], fields_info[i].field_type});
                    Lua.push(self.L, args[i]);
                }
                // Calculating retval count
                comptime var retValCount = switch (@typeInfo(RetType.?)) {
                    .Void => 0,
                    .Struct => |StructInfo| StructInfo.fields.len,
                    else => 1,
                };
                // Calling
                if (lualib.lua_pcallk(self.L, fields_info.len, retValCount, 0, 0, null) != lualib.LUA_OK) {
                    return error.lua_runtime_error;
                }
                // Getting return value(s)
                if (retValCount > 0) {
                    return Lua.pop(RetType.?, self.L);
                }
            }
        };
    }

    const Table = struct {
        const Self = @This();

        L: *lualib.lua_State,
        allocator: *std.mem.Allocator,
        ref: c_int = undefined,

        // This 'Init' assumes, that the top element of the stack is a Lua table
        pub fn init(_L: *lualib.lua_State, _allocator: *std.mem.Allocator) Self {
            const _ref = lualib.luaL_ref(_L, lualib.LUA_REGISTRYINDEX);
            var res = Self{
                .L = _L,
                .allocator = _allocator,
                .ref = _ref,
            };
            return res;
        }

        // Unregister this shit
        pub fn destroy(self: *const Self) void {
            lualib.luaL_unref(self.L, lualib.LUA_REGISTRYINDEX, self.ref);
        }

        pub fn reference(self: *const Self) Self {
            _ = lualib.lua_rawgeti(self.L, lualib.LUA_REGISTRYINDEX, self.ref);
            return Table.init(self.L, self.allocator);
        }

        pub fn set(self: *const Self, key: anytype, value: anytype) void {
            // Getting table reference
            _ = lualib.lua_rawgeti(self.L, lualib.LUA_REGISTRYINDEX, self.ref);
            // Push key, value
            Lua.push(self.L, key);
            Lua.push(self.L, value);
            // Set
            lualib.lua_settable(self.L, -3);
        }

        pub fn get(self: *const Self, comptime T: type, key: anytype) !T {
            // Getting table by reference
            _ = lualib.lua_rawgeti(self.L, lualib.LUA_REGISTRYINDEX, self.ref);
            // Push key
            Lua.push(self.L, key);
            // Get
            _ = lualib.lua_gettable(self.L, -2);
            return try Lua.pop(T, self.L);
        }

        pub fn getResource(self: *const Self, comptime T: type, key: anytype) !T {
            // Getting table reference
            _ = lualib.lua_rawgeti(self.L, lualib.LUA_REGISTRYINDEX, self.ref);
            // Push key
            Lua.push(self.L, key);
            // Get
            _ = lualib.lua_gettable(self.L, -2);
            return try Lua.popResource(T, self.L, self.allocator);
        }
    };

    fn Ref(comptime T: type) type {
        return struct {
            const Self = @This();

            luaRef: c_int,
            ptr: T,

            fn init(_ref: c_int, _ptr: *T) Self {
                return Self {
                    .luaRef = _ref,
                    .ptr = _ptr,
                };
            }
        };
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////
    fn pushSlice(comptime T: type, L: *lualib.lua_State, values: []const T) void {
        lualib.lua_createtable(L, @intCast(c_int, values.len), 0);

        for (values) |value, i| {
            push(L, i + 1);
            push(L, value);
            lualib.lua_settable(L, -3);
        }
    }

    fn push(L: *lualib.lua_State, value: anytype) void {
        const T = @TypeOf(value);
        switch (@typeInfo(T)) {
            .Void => lualib.lua_pushnil(L),
            .Bool => lualib.lua_pushboolean(L, @boolToInt(value)),
            .Int, .ComptimeInt => lualib.lua_pushinteger(L, @intCast(c_longlong, value)),
            .Float, .ComptimeFloat => lualib.lua_pushnumber(L, value),
            .Array => |info| {
                pushSlice(info.child, L, value[0..]);
            },
            .Pointer => |PointerInfo| switch (PointerInfo.size) {
                .Slice => {
                    if (PointerInfo.child == u8) {
                        _ = lualib.lua_pushlstring(L, value.ptr, value.len);
                    } else {
                        @compileError("invalid type: '" ++ @typeName(T) ++ "'");
                    }
                },
                .One => {
                    if (@TypeOf(PointerInfo.child) == @TypeOf([]u8)) {
                        _ = lualib.lua_pushstring(L, @ptrCast([*c]const u8, value));
                    } else {
                        @compileError("invalid type: '" ++ @typeName(T) ++ "'");
                    }
                },
                .Many => {
                    if (@TypeOf(PointerInfo.child) == @TypeOf([]u8)) {
                        _ = lualib.lua_pushstring(L, @ptrCast([*c]const u8, value));
                    } else {
                        @compileError("invalid type: '" ++ @typeName(T) ++ "'");
                    }
                },
                .C => {
                    if (@TypeOf(PointerInfo.child) == @TypeOf([]u8)) {
                        _ = lualib.lua_pushstring(L, value);
                    } else {
                        @compileError("invalid type: '" ++ @typeName(T) ++ "'");
                    }
                },
            },
            .Fn => {
                const Helper = ZigCallHelper(@TypeOf(value));
                Helper.pushFunctor(L, value) catch unreachable;
            },
            .Struct => |_| {
                comptime var funIdx = std.mem.indexOf(u8, @typeName(T), "Function") orelse -1;
                comptime var tblIdx = std.mem.indexOf(u8, @typeName(T), "Table") orelse -1;
                if (funIdx >= 0 or tblIdx >= 0) {
                    _ = lualib.lua_rawgeti(L, lualib.LUA_REGISTRYINDEX, value.ref);
                } else @compileError("Only LuaFunction ands Lua.Table supported; '" ++ @typeName(T) ++ "' not.");
            },
            // .Type => {
            // },
            else => @compileError("Unsupported type: '" ++ @typeName(@TypeOf(value)) ++ "'"),
        }
    }

    fn pop(comptime T: type, L: *lualib.lua_State) !T {
        defer lualib.lua_pop(L, 1);
        switch (@typeInfo(T)) {
            .Bool => {
                var res = lualib.lua_toboolean(L, -1);
                return if (res > 0) true else false;
            },
            .Int, .ComptimeInt => {
                var isnum: i32 = 0;
                var result: T = @intCast(T, lualib.lua_tointegerx(L, -1, isnum));
                return result;
            },
            .Float, .ComptimeFloat => {
                var isnum: i32 = 0;
                var result: T = @floatCast(T, lualib.lua_tonumberx(L, -1, isnum));
                return result;
            },
            // Only string, allocless get (Lua holds the pointer, it is only a slice pointing to it)
            .Pointer => |PointerInfo| switch (PointerInfo.size) {
                .Slice => {
                    // [] const u8 case
                    if (PointerInfo.child == u8 and PointerInfo.is_const) {
                        var len: usize = 0;
                        var ptr = lualib.lua_tolstring(L, -1, @ptrCast([*c]usize, &len));
                        var result: T = ptr[0..len];
                        return result;
                    } else @compileError("Only '[]const u8' (aka string) is supported allocless.");
                },
                .One => {
                    var optionalTbl = registeredTypes.get(@typeName(PointerInfo.child));
                    if (optionalTbl) |tbl| {
                        var result = @ptrCast(T, @alignCast(@alignOf(PointerInfo.child), lualib.luaL_checkudata(L, -1, @ptrCast([*c]const u8, tbl[0..]))));
                        return result;
                    } else { 
                        return error.invalidType; 
                    }
                },
                else => @compileError("invalid type: '" ++ @typeName(T) ++ "'"),
            },
            .Struct => |StructInfo| {
                if (StructInfo.is_tuple) {
                    @compileError("Tuples are not supported.");
                }
                comptime var funIdx = std.mem.indexOf(u8, @typeName(T), "Function") orelse -1;
                comptime var tblIdx = std.mem.indexOf(u8, @typeName(T), "Table") orelse -1;
                if (funIdx >= 0 or tblIdx >= 0) {
                    @compileError("Only allocGet supports Lua.Function and Lua.Table. Your type '" ++ @typeName(T) ++ "' is not supported.");
                }

                var result: T = .{ 0, 0 };
                comptime var i = 0;
                const fields_info = std.meta.fields(T);
                inline while (i < fields_info.len) : (i += 1) {
                    //std.log.info("Parameter: {}: {} ({s})", .{i, args[i], fields_info[i].field_type});
                    result[i] = pop(@TypeOf(result[i]), L);
                }
            },
            else => @compileError("invalid type: '" ++ @typeName(T) ++ "'"),
        }
    }

    fn popResource(comptime T: type, L: *lualib.lua_State, allocator: *std.mem.Allocator) !T {
        switch (@typeInfo(T)) {
            .Pointer => |PointerInfo| switch (PointerInfo.size) {
                .Slice => {
                    defer lualib.lua_pop(L, 1);
                    if (lualib.lua_type(L, -1) == lualib.LUA_TTABLE) {
                        lualib.lua_len(L, -1);
                        const len = try pop(u64, L);
                        var res = try allocator.alloc(PointerInfo.child, @intCast(usize, len));
                        var i: u32 = 0;
                        while (i < len) : (i += 1) {
                            push(L, i + 1);
                            _ = lualib.lua_gettable(L, -2);
                            res[i] = try pop(PointerInfo.child, L);
                        }
                        return res;
                    } else {
                        std.log.info("Ajjaj 2", .{});
                        return error.bad_type;
                    }
                },
                else => @compileError("Only Slice is supported."),
            },
            .Struct => |_| {
                comptime var funIdx = std.mem.indexOf(u8, @typeName(T), "Function") orelse -1;
                comptime var tblIdx = std.mem.indexOf(u8, @typeName(T), "Table") orelse -1;
                if (funIdx >= 0) {
                    if (lualib.lua_type(L, -1) == lualib.LUA_TFUNCTION) {
                        return T.init(L, allocator);
                    } else {
                        defer lualib.lua_pop(L, 1);
                        return error.bad_type;
                    }
                } else if (tblIdx >= 0) {
                    if (lualib.lua_type(L, -1) == lualib.LUA_TTABLE) {
                        return T.init(L, allocator);
                    } else {
                        defer lualib.lua_pop(L, 1);
                        return error.bad_type;
                    }
                } else @compileError("Only LuaFunction supported; '" ++ @typeName(T) ++ "' not.");
            },
            else => @compileError("invalid type: '" ++ @typeName(T) ++ "'"),
        }
    }

    // It is a helper function, with two responsibilities:
    // 1. When it's called with only a type (allocator and value are both null) in compile time it returns that
    //    the given type is allocated or not
    // 2. When it's called with full arguments it cleans up.
    fn allocateDeallocateHelper(comptime T: type, comptime deallocate: bool, allocator: ?*std.mem.Allocator, value: ?T) bool {
        switch (@typeInfo(T)) {
            .Pointer => |PointerInfo| switch (PointerInfo.size) {
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
            .Struct => |_| {
                comptime var funIdx = std.mem.indexOf(u8, @typeName(T), "Function") orelse -1;
                comptime var tblIdx = std.mem.indexOf(u8, @typeName(T), "Table") orelse -1;
                if (funIdx >= 0 or tblIdx >= 0) {
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

    fn ZigCallHelper(comptime funcType: type) type {
        const info = @typeInfo(funcType);
        if (info != .Fn) {
            @compileError("ZigCallHelper expects a function type");
        }

        const ReturnType = info.Fn.return_type.?;
        const ArgTypes = std.meta.ArgsTuple(funcType);
        const resultCnt = if (ReturnType == void) 0 else 1;

        return struct {
            pub const LowLevelHelpers = struct {
                const Self = @This();

                args: ArgTypes = undefined,
                result: ReturnType = undefined,

                pub fn init() Self {
                    return Self{};
                }

                fn prepareArgs(self: *Self, L: ?*lualib.lua_State) !void {
                    // Prepare arguments
                    comptime var i = self.args.len - 1;
                    inline while (i > -1) : (i -= 1) {
                        if (comptime allocateDeallocateHelper(@TypeOf(self.args[i]), false, null, null)) {
                            self.args[i] = popResource(@TypeOf(self.args[i]), L.?, luaAllocator) catch unreachable;
                        } else {
                            self.args[i] = pop(@TypeOf(self.args[i]), L.?) catch unreachable;
                        }
                    }
                }

                fn call(self: *Self, func: funcType) !void {
                    self.result = @call(.{}, func, self.args);
                }

                fn pushResult(self: *Self, L: ?*lualib.lua_State) !void {
                    if (resultCnt > 0) {
                        push(L.?, self.result);
                    }
                }

                fn destroyArgs(self: *Self) !void {
                    comptime var i = self.args.len - 1;
                    inline while (i > -1) : (i -= 1) {
                        _ = allocateDeallocateHelper(@TypeOf(self.args[i]), true, luaAllocator, self.args[i]);
                    }
                    _ = allocateDeallocateHelper(ReturnType, true, luaAllocator, self.result);
                }
            };

            pub fn pushFunctor(L: ?*lualib.lua_State, func: funcType) !void {
                const funcPtrAsInt = @intCast(c_longlong, @ptrToInt(func));
                lualib.lua_pushinteger(L, funcPtrAsInt);
                std.log.info("[Functor] Function ptr: {}", .{funcPtrAsInt});

                const cfun = struct {
                    fn helper(_L: ?*lualib.lua_State) callconv(.C) c_int {
                        var f: LowLevelHelpers = undefined;
                        // Prepare arguments from stack
                        f.prepareArgs(_L) catch unreachable;
                        // Get func pointer upvalue as int => convert to func ptr then call
                        var ptr = lualib.lua_tointegerx(_L, lualib.lua_upvalueindex(1), null);
                        f.call(@intToPtr(funcType, @intCast(usize, ptr))) catch unreachable;
                        // The end
                        f.pushResult(_L) catch unreachable;
                        // Release arguments
                        f.destroyArgs() catch unreachable;
                        return resultCnt;
                    }
                }.helper;
                lualib.lua_pushcclosure(L, cfun, 1);
            }
        };
    }

    // Credit: https://github.com/daurnimator/zig-autolua
    fn alloc(ud: ?*c_void, ptr: ?*c_void, osize: usize, nsize: usize) callconv(.C) ?*c_void {
        const c_alignment = 16;
        const allocator = @ptrCast(*std.mem.Allocator, @alignCast(@alignOf(std.mem.Allocator), ud));
        if (@ptrCast(?[*]align(c_alignment) u8, @alignCast(c_alignment, ptr))) |previous_pointer| {
            const previous_slice = previous_pointer[0..osize];
            if (osize >= nsize) {
                // Lua assumes that the allocator never fails when osize >= nsize.
                return allocator.alignedShrink(previous_slice, c_alignment, nsize).ptr;
            } else {
                return (allocator.reallocAdvanced(previous_slice, c_alignment, nsize, .exact) catch return null).ptr;
            }
        } else {
            // osize is any of LUA_TSTRING, LUA_TTABLE, LUA_TFUNCTION, LUA_TUSERDATA, or LUA_TTHREAD
            // when (and only when) Lua is creating a new object of that type.
            // When osize is some other value, Lua is allocating memory for something else.
            return (allocator.alignedAlloc(u8, c_alignment, nsize) catch return null).ptr;
        }
    }
};

const TestStruct = struct {
    a: i32 = 0,
    b: bool = false,
    c: InnerStruct = undefined,

    const InnerStruct = struct {
        c: []const u8,
    };

    pub fn init(a: i32) TestStruct {
        std.log.info("Init: {}", .{a});
        return TestStruct{
            .a = a,
            .b = true,
        };
    }

    pub fn destroy(self: *TestStruct) void {
        std.log.info("[TestStruct destroy] a: {}", .{self.a});
    }

    fn fun0(_: *TestStruct, a: i32) i32 {
        return 2 * a;
    }

    pub fn fun1(_: *TestStruct, _: []const u8) i32 {
        return 42;
    }

    pub fn fun2(self: *TestStruct, a: i32, b: i32) i32 {
        std.log.info("State: {}, Input: {}, {}", .{self.a, a, b});
        return a + b;
    }

    var d: i32 = 0;
};

const zzz = struct {
    name: []const u8,
    id: i32,
};

const mucuka = struct {
    a: i32 = 42,
    b: bool = true,
};

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var lua = try Lua.init(&gpa.allocator);
    defer lua.destroy();
    lua.openLibs();

    //@compileLog("Name: '" ++ @typeName(LuaRef(TestCustomTypes)) ++ "'");
}

test "set/get scalar" {
    var lua = try Lua.init(std.testing.allocator);
    defer lua.destroy();
    const int16In: i16 = 1;
    const int32In: i32 = 2;
    const int64In: i64 = 3;

    const f16In: f16 = 3.1415;
    const f32In: f32 = 3.1415;
    const f64In: f64 = 3.1415;

    const bIn: bool = true;

    lua.set("int16", int16In);
    lua.set("int32", int32In);
    lua.set("int64", int64In);

    lua.set("float16", f16In);
    lua.set("float32", f32In);
    lua.set("float64", f64In);

    lua.set("bool", bIn);

    var int16Out = try lua.get(i16, "int16");
    var int32Out = try lua.get(i32, "int32");
    var int64Out = try lua.get(i64, "int64");

    var f16Out = try lua.get(f16, "float16");
    var f32Out = try lua.get(f32, "float32");
    var f64Out = try lua.get(f64, "float64");

    var bOut = try lua.get(bool, "bool");

    try std.testing.expectEqual(int16In, int16Out);
    try std.testing.expectEqual(int32In, int32Out);
    try std.testing.expectEqual(int64In, int64Out);

    try std.testing.expectEqual(f16In, f16Out);
    try std.testing.expectEqual(f32In, f32Out);
    try std.testing.expectEqual(f64In, f64Out);

    try std.testing.expectEqual(bIn, bOut);
}

test "set/get string" {
    var lua = try Lua.init(std.testing.allocator);
    defer lua.destroy();

    var strMany: [*]const u8 = "macilaci";
    var strSlice: []const u8 = "macilaic";
    var strOne = "macilaci";
    var strC: [*c]const u8 = "macilaci";

    const cstrMany: [*]const u8 = "macilaci";
    const cstrSlice: []const u8 = "macilaic";
    const cstrOne = "macilaci";
    const cstrC: [*c]const u8 = "macilaci";

    lua.set("stringMany", strMany);
    lua.set("stringSlice", strSlice);
    lua.set("stringOne", strOne);
    lua.set("stringC", strC);

    lua.set("cstringMany", cstrMany);
    lua.set("cstringSlice", cstrSlice);
    lua.set("cstringOne", cstrOne);
    lua.set("cstringC", cstrC);

    const retStrMany = try lua.get([]const u8, "stringMany");
    const retCStrMany = try lua.get([]const u8, "cstringMany");
    const retStrSlice = try lua.get([]const u8, "stringSlice");
    const retCStrSlice = try lua.get([]const u8, "cstringSlice");

    const retStrOne = try lua.get([]const u8, "stringOne");
    const retCStrOne = try lua.get([]const u8, "cstringOne");
    const retStrC = try lua.get([]const u8, "stringC");
    const retCStrC = try lua.get([]const u8, "cstringC");

    try std.testing.expect(std.mem.eql(u8, strMany[0..retStrMany.len], retStrMany));
    try std.testing.expect(std.mem.eql(u8, strSlice[0..retStrSlice.len], retStrSlice));
    try std.testing.expect(std.mem.eql(u8, strOne[0..retStrOne.len], retStrOne));
    try std.testing.expect(std.mem.eql(u8, strC[0..retStrC.len], retStrC));

    try std.testing.expect(std.mem.eql(u8, cstrMany[0..retStrMany.len], retCStrMany));
    try std.testing.expect(std.mem.eql(u8, cstrSlice[0..retStrSlice.len], retCStrSlice));
    try std.testing.expect(std.mem.eql(u8, cstrOne[0..retStrOne.len], retCStrOne));
    try std.testing.expect(std.mem.eql(u8, cstrC[0..retStrC.len], retCStrC));
}

test "set/get slice of primitive type (scalar, unmutable string)" {
    var lua = try Lua.init(std.testing.allocator);
    defer lua.destroy();

    const boolSlice = [_]bool{ true, false, true };
    const intSlice = [_]i32{ 4, 5, 3, 4, 0 };
    const strSlice = [_][]const u8{ "Macilaci", "Gyumifagyi", "Angolhazi" };

    lua.set("boolSlice", boolSlice);
    lua.set("intSlice", intSlice);
    lua.set("strSlice", strSlice);

    const retBoolSlice = try lua.getResource([]i32, "boolSlice");
    defer lua.release(retBoolSlice);

    const retIntSlice = try lua.getResource([]i32, "intSlice");
    defer lua.release(retIntSlice);

    const retStrSlice = try lua.getResource([][]const u8, "strSlice");
    defer lua.release(retStrSlice);

    for (retIntSlice) |v, i| {
        try std.testing.expectEqual(v, intSlice[i]);
    }

    for (retStrSlice) |v, i| {
        try std.testing.expect(std.mem.eql(u8, v, strSlice[i]));
    }
}

test "simple Zig => Lua function call" {
    var lua = try Lua.init(std.testing.allocator);
    defer lua.destroy();

    lua.openLibs();

    const lua_command =
        \\function test_1() end
        \\function test_2(a) end
        \\function test_3(a) return a; end
        \\function test_4(a,b) return a+b; end
    ;

    lua.run(lua_command);

    var fun1 = try lua.getResource(Lua.Function(fn () void), "test_1");
    defer lua.release(fun1);

    var fun2 = try lua.getResource(Lua.Function(fn (a: i32) void), "test_2");
    defer lua.release(fun2);

    var fun3_1 = try lua.getResource(Lua.Function(fn (a: i32) i32), "test_3");
    defer lua.release(fun3_1);

    var fun3_2 = try lua.getResource(Lua.Function(fn (a: []const u8) []const u8), "test_3");
    defer lua.release(fun3_2);

    var fun4 = try lua.getResource(Lua.Function(fn (a: i32, b: i32) i32), "test_4");
    defer lua.release(fun4);

    try fun1.call(.{});
    try fun2.call(.{42});
    const res3_1 = try fun3_1.call(.{42});
    try std.testing.expectEqual(res3_1, 42);

    const res3_2 = try fun3_2.call(.{"Bela"});
    try std.testing.expect(std.mem.eql(u8, res3_2, "Bela"));

    const res4 = try fun4.call(.{ 42, 24 });
    try std.testing.expectEqual(res4, 66);
}

var testResult0: bool = false;
fn testFun0() void {
    testResult0 = true;
}

var testResult1: i32 = 0;
fn testFun1(a: i32, b: i32) void {
    testResult1 = a - b;
}

var testResult2: i32 = 0;
fn testFun2(a: []const u8) void {
    for (a) |ch| {
        testResult2 += ch - '0';
    }
}

var testResult3: i32 = 0;
fn testFun3(a: []const u8, b: i32) void {
    for (a) |ch| {
        testResult3 += ch - '0';
    }
    testResult3 -= b;
}

test "simple Lua => Zig function call" {
    var lua = try Lua.init(std.testing.allocator);
    defer lua.destroy();

    lua.openLibs();

    lua.set("testFun0", testFun0);
    lua.set("testFun1", testFun1);
    lua.set("testFun2", testFun2);
    lua.set("testFun3", testFun3);

    lua.run("testFun0()");
    try std.testing.expect(testResult0 == true);

    lua.run("testFun1(42,10)");
    try std.testing.expect(testResult1 == 32);

    lua.run("testFun2('0123456789')");
    try std.testing.expect(testResult2 == 45);

    lua.run("testFun3('0123456789', -10)");
    try std.testing.expect(testResult3 == 55);

    testResult0 = false;
    testResult1 = 0;
    testResult2 = 0;
    testResult3 = 0;

    lua.run("testFun3('0123456789', -10)");
    try std.testing.expect(testResult3 == 55);

    lua.run("testFun2('0123456789')");
    try std.testing.expect(testResult2 == 45);

    lua.run("testFun1(42,10)");
    try std.testing.expect(testResult1 == 32);

    lua.run("testFun0()");
    try std.testing.expect(testResult0 == true);
}

fn testFun4(a: []const u8) []const u8 {
    return a;
}

fn testFun5(a: i32, b: i32) i32 {
    return a - b;
}

test "simple Zig => Lua => Zig function call" {
    var lua = try Lua.init(std.testing.allocator);
    defer lua.destroy();

    lua.openLibs();

    lua.set("testFun4", testFun4);
    lua.set("testFun5", testFun5);

    lua.run("function luaTestFun4(a) return testFun4(a); end");
    lua.run("function luaTestFun5(a,b) return testFun5(a,b); end");

    var fun4 = try lua.getResource(Lua.Function(fn (a: []const u8) []const u8), "luaTestFun4");
    defer lua.release(fun4);

    var fun5 = try lua.getResource(Lua.Function(fn (a: i32, b: i32) i32), "luaTestFun5");
    defer lua.release(fun5);

    var res4 = try fun4.call(.{"macika"});
    var res5 = try fun5.call(.{ 42, 1 });

    try std.testing.expect(std.mem.eql(u8, res4, "macika"));
    try std.testing.expect(res5 == 41);
}

fn testLuaInnerFun(fun: Lua.Function(fn (a: i32) i32)) i32 {
    var res = fun.call(.{42}) catch unreachable;
    return res;
}

test "Lua function injection into Zig function" {
    var lua = try Lua.init(std.testing.allocator);
    defer lua.destroy();

    lua.openLibs();
    // Binding on Zig side
    lua.run("function getInt(a) return a+1; end");
    var luafun = try lua.getResource(Lua.Function(fn (a: i32) i32), "getInt");
    defer lua.release(luafun);

    var result = testLuaInnerFun(luafun);
    std.log.info("Zig Result: {}", .{result});

    // Binding on Lua side
    lua.set("zigFunction", testLuaInnerFun);

    const lua_command =
        \\function getInt(a) return a+1; end
        \\zigFunction(getInt);
    ;

    lua.run(lua_command);
}

fn zigInnerFun(a: i32) i32 {
    return 2 * a;
}

test "Zig function injection into Lua function" {
    var lua = try Lua.init(std.testing.allocator);
    defer lua.destroy();

    lua.openLibs();

    // Binding
    lua.set("zigFunction", zigInnerFun);

    const lua_command =
        \\function test(a) res = a(2); return res; end
        \\test(zigFunction);
    ;

    lua.run(lua_command);
}

fn testSliceInput(a: []i32) i32 {
    var sum: i32 = 0;
    for (a) |v| {
        sum += v;
    }
    return sum;
}

test "Slice input to Zig function" {
    var lua = try Lua.init(std.testing.allocator);
    defer lua.destroy();

    lua.openLibs();

    // Binding
    lua.set("sumFunction", testSliceInput);

    const lua_command =
        \\res = sumFunction({1,2,3});
    ;

    lua.run(lua_command);
}

test "Lua.Table allocless set/get tests" {
    var lua = try Lua.init(std.testing.allocator);
    defer lua.destroy();

    lua.openLibs();

    // Create table
    var originalTbl = try lua.createTableResource();
    defer originalTbl.destroy();
    lua.set("tbl", originalTbl);

    originalTbl.set("owner", true);

    var tbl = try lua.getResource(Lua.Table, "tbl");
    defer lua.release(tbl);

    const owner = try tbl.get(bool, "owner");
    try std.testing.expect(owner);

    // Numeric
    const int16In: i16 = 1;
    const int32In: i32 = 2;
    const int64In: i64 = 3;

    const f16In: f16 = 3.1415;
    const f32In: f32 = 3.1415;
    const f64In: f64 = 3.1415;

    const bIn: bool = true;

    tbl.set("int16", int16In);
    tbl.set("int32", int32In);
    tbl.set("int64", int64In);

    tbl.set("float16", f16In);
    tbl.set("float32", f32In);
    tbl.set("float64", f64In);

    tbl.set("bool", bIn);

    var int16Out = try tbl.get(i16, "int16");
    var int32Out = try tbl.get(i32, "int32");
    var int64Out = try tbl.get(i64, "int64");

    var f16Out = try tbl.get(f16, "float16");
    var f32Out = try tbl.get(f32, "float32");
    var f64Out = try tbl.get(f64, "float64");

    var bOut = try tbl.get(bool, "bool");

    try std.testing.expectEqual(int16In, int16Out);
    try std.testing.expectEqual(int32In, int32Out);
    try std.testing.expectEqual(int64In, int64Out);

    try std.testing.expectEqual(f16In, f16Out);
    try std.testing.expectEqual(f32In, f32Out);
    try std.testing.expectEqual(f64In, f64Out);

    try std.testing.expectEqual(bIn, bOut);

    // String
    const str: []const u8 = "Hello World";
    tbl.set("str", str);

    const retStr = try tbl.get([]const u8, "str");
    try std.testing.expect(std.mem.eql(u8, str, retStr));
}

fn tblFun(a: i32) i32 {
    return 3 * a;
}

test "Lua.Table inner table tests" {
    var lua = try Lua.init(std.testing.allocator);
    defer lua.destroy();

    lua.openLibs();

    // Create table
    var tbl = try lua.createTableResource();
    defer lua.release(tbl);

    lua.set("tbl", tbl);

    var inTbl0 = try lua.createTableResource();
    defer lua.release(inTbl0);

    var inTbl1 = try lua.createTableResource();
    defer lua.release(inTbl1);

    inTbl1.set("str", "string");
    inTbl1.set("int32", 68);
    inTbl1.set("fn", tblFun);

    inTbl0.set(1, "string");
    inTbl0.set(2, 3.1415);
    inTbl0.set(3, 42);
    inTbl0.set("table", inTbl1);

    tbl.set("innerTable", inTbl0);

    var retTbl = try lua.getResource(Lua.Table, "tbl");
    defer lua.release(retTbl);

    var retInnerTable = try retTbl.getResource(Lua.Table, "innerTable");
    defer lua.release(retInnerTable);

    var str = try retInnerTable.get([]const u8, 1);
    var float = try retInnerTable.get(f32, 2);
    var int = try retInnerTable.get(i32, 3);

    try std.testing.expect(std.mem.eql(u8, str, "string"));
    try std.testing.expect(float == 3.1415);
    try std.testing.expect(int == 42);

    var retInner2Table = try retInnerTable.getResource(Lua.Table, "table");
    defer lua.release(retInner2Table);

    str = try retInner2Table.get([]const u8, "str");
    int = try retInner2Table.get(i32, "int32");
    var func = try retInner2Table.getResource(Lua.Function(fn (a: i32) i32), "fn");
    defer lua.release(func);
    var funcRes = try func.call(.{42});

    try std.testing.expect(std.mem.eql(u8, str, "string"));
    try std.testing.expect(int == 68);
    try std.testing.expect(funcRes == 3 * 42);
}

var luaTableArgSum: i32 = 0;
fn testLuaTableArg(t: Lua.Table) i32 {
    var a = t.get(i32, "a") catch -1;
    var b = t.get(i32, "b") catch -1;
    luaTableArgSum = a + b;
    return luaTableArgSum;
}

test "Function with Lua.Table argument" {
    var lua = try Lua.init(std.testing.allocator);
    defer lua.destroy();

    lua.openLibs();
    // Zig side
    var tbl = try lua.createTableResource();
    defer lua.release(tbl);

    tbl.set("a", 42);
    tbl.set("b", 128);
    var zigRes = testLuaTableArg(tbl);

    try std.testing.expect(zigRes == 42 + 128);

    // Lua side
    lua.set("sumFn", testLuaTableArg);
    lua.run("function test() return sumFn({a=1, b=2}); end");

    var luaFun = try lua.getResource(Lua.Function(fn () i32), "test");
    defer lua.release(luaFun);

    var luaRes = try luaFun.call(.{});
    try std.testing.expect(luaRes == 1 + 2);
}

fn testLuaTableArgOut(t: Lua.Table) Lua.Table {
    t.set(1, 42);
    t.set(2, 128);
    return t;
}

test "Function with Lua.Table result" {
    var lua = try Lua.init(std.testing.allocator);
    defer lua.destroy();

    lua.openLibs();
    lua.injectPrettyPrint();
    // Zig side
    var tbl = try lua.createTableResource();
    defer lua.release(tbl);

    var zigRes = testLuaTableArgOut(tbl);

    var zigA = try zigRes.get(i32, 1);
    var zigB = try zigRes.get(i32, 2);

    try std.testing.expect((zigA + zigB) == 42 + 128);

    // Lua side
    lua.set("tblFn", testLuaTableArgOut);
    //lua.run("function test() tbl = tblFn({}); return tbl[1] + tbl[2]; end");
    lua.run("function test() tbl = tblFn({}); return tbl[1] + tbl[2]; end");

    var luaFun = try lua.getResource(Lua.Function(fn () i32), "test");
    defer lua.release(luaFun);

    var luaRes = try luaFun.call(.{});
    try std.testing.expect(luaRes == 42 + 128);
}


const TestCustomTypes = struct {
    a: i32,
    b: f32,
    c: []const u8,
    d: bool,

    pub fn init(_a: i32, _b: f32, _c: []const u8, _d: bool) TestCustomTypes {
        return TestCustomTypes {
            .a = _a,
            .b = _b,
            .c = _c,
            .d = _d,
        };
    }

    pub fn destroy(_: *TestCustomTypes) void {

    }

    pub fn getA(self: *TestCustomTypes) i32 { 
        return self.a;
    }

    pub fn getB(self: *TestCustomTypes) f32 { 
        return self.b;
    }

    pub fn getC(self: *TestCustomTypes) []const u8 { 
        return self.c;
    }

    pub fn getD(self: *TestCustomTypes) bool { 
        return self.d;
    }

    pub fn reset(self: *TestCustomTypes) void {
        self.a = 0;
        self.b = 0;
        self.c = "";
        self.d = false;
    }
    
    pub fn store(self: *TestCustomTypes, _a: i32, _b: f32, _c: []const u8, _d: bool) void {
        self.a = _a;
        self.b = _b;
        self.c = _c;
        self.d = _d;
    }
};

test "Register custom types I: allocless in/out member functions arguments" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var lua = try Lua.init(&gpa.allocator);
    defer lua.destroy();
    lua.openLibs();

    _ = try lua.newUserType(TestCustomTypes);

    const cmd = 
        \\o = TestCustomTypes.new(42, 42.0, "life", true)
        \\function getA() return o:getA(); end
        \\function getB() return o:getB(); end
        \\function getC() return o:getC(); end
        \\function getD() return o:getD(); end
        \\function reset() o:reset() end
        \\function store(a,b,c,d) o:store(a,b,c,d) end
    ;
    lua.run(cmd);

    var getA = try lua.getResource(Lua.Function(fn() i32), "getA");
    defer lua.release(getA);

    var getB = try lua.getResource(Lua.Function(fn() f32), "getB");
    defer lua.release(getB);

    var getC = try lua.getResource(Lua.Function(fn() [] const u8), "getC");
    defer lua.release(getC);

    var getD = try lua.getResource(Lua.Function(fn() bool), "getD");
    defer lua.release(getD);

    var reset = try lua.getResource(Lua.Function(fn() void), "reset");
    defer lua.release(reset);

    var store = try lua.getResource(Lua.Function(fn(_a: i32, _b: f32, _c: []const u8, _d: bool) void), "store");
    defer lua.release(store);

    var resA0 = try getA.call(.{});
    try std.testing.expect(resA0 == 42);

    var resB0 = try getB.call(.{});
    try std.testing.expect(resB0 == 42.0);

    var resC0 = try getC.call(.{});
    try std.testing.expect(std.mem.eql(u8, resC0, "life"));

    var resD0 = try getD.call(.{});
    try std.testing.expect(resD0 == true);

    try store.call(.{1, 1.0, "death", false});

    var resA1 = try getA.call(.{});
    try std.testing.expect(resA1 == 1);

    var resB1 = try getB.call(.{});
    try std.testing.expect(resB1 == 1.0);

    var resC1 = try getC.call(.{});
    try std.testing.expect(std.mem.eql(u8, resC1, "death"));

    var resD1 = try getD.call(.{});
    try std.testing.expect(resD1 == false);

    try reset.call(.{});

    var resA2 = try getA.call(.{});
    try std.testing.expect(resA2 == 0);

    var resB2 = try getB.call(.{});
    try std.testing.expect(resB2 == 0.0);

    var resC2 = try getC.call(.{});
    try std.testing.expect(std.mem.eql(u8, resC2, ""));

    var resD2 = try getD.call(.{});
    try std.testing.expect(resD2 == false);
}

test "Registered user type as global without ownership" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var lua = try Lua.init(&gpa.allocator);
    defer lua.destroy();
    lua.openLibs();

    _ = try lua.newUserType(TestCustomTypes);

    lua.run("o = TestCustomTypes.new(42, 42.0, 'life', true)");

    var ptr = try lua.get(*TestCustomTypes, "o");

    try std.testing.expect(ptr.a == 42);
    try std.testing.expect(ptr.b == 42.0);
    try std.testing.expect(std.mem.eql(u8, ptr.c, "life"));
    try std.testing.expect(ptr.d == true);

    lua.run("o:reset()");

    try std.testing.expect(ptr.a == 0);
    try std.testing.expect(ptr.b == 0.0);
    try std.testing.expect(std.mem.eql(u8, ptr.c, ""));
    try std.testing.expect(ptr.d == false);
}

fn testCustomTypeSwap(ptr0: *TestCustomTypes, ptr1: *TestCustomTypes) void {
    var tmp: TestCustomTypes = undefined;
    tmp = ptr0.*;
    ptr0.* = ptr1.*;
    ptr1.* = tmp;
}

test "Zig function with registered user type arguments" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var lua = try Lua.init(&gpa.allocator);
    defer lua.destroy();
    lua.openLibs();

    _ = try lua.newUserType(TestCustomTypes);
    lua.set("swap", testCustomTypeSwap);

    const cmd = 
        \\o0 = TestCustomTypes.new(42, 42.0, 'life', true)
        \\o1 = TestCustomTypes.new(0, 1.0, 'test', false)
        \\swap(o0, o1)
    ;

    lua.run(cmd);

    var ptr0 = try lua.get(*TestCustomTypes, "o0");
    var ptr1 = try lua.get(*TestCustomTypes, "o1");

    try std.testing.expect(ptr0.a == 0);
    try std.testing.expect(ptr0.b == 1.0);
    try std.testing.expect(std.mem.eql(u8, ptr0.c, "test"));
    try std.testing.expect(ptr0.d == false);

    try std.testing.expect(ptr1.a == 42);
    try std.testing.expect(ptr1.b == 42.0);
    try std.testing.expect(std.mem.eql(u8, ptr1.c, "life"));
    try std.testing.expect(ptr1.d == true);
}