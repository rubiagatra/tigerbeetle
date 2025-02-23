const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;

const constants = @import("../constants.zig");
const fuzz = @import("../testing/fuzz.zig");
const vsr = @import("../vsr.zig");
const allocator = fuzz.allocator;

const log = std.log.scoped(.lsm_forest_fuzz);
const tracer = @import("../tracer.zig");

const Transfer = @import("../tigerbeetle.zig").Transfer;
const Account = @import("../tigerbeetle.zig").Account;
const Storage = @import("../testing/storage.zig").Storage;
const StateMachine = @import("../state_machine.zig").StateMachineType(Storage, constants.state_machine_config);
const GridType = @import("../vsr/grid.zig").GridType;
const GrooveType = @import("groove.zig").GrooveType;
const Forest = StateMachine.Forest;

const Grid = GridType(Storage);
const SuperBlock = vsr.SuperBlockType(Storage);

pub const tigerbeetle_config = @import("../config.zig").configs.fuzz_min;

const FuzzOpAction = union(enum) {
    // TODO Test secondary index lookups and range queries.
    compact: struct {
        op: u64,
        checkpoint: bool,
    },
    put_account: struct {
        op: u64,
        account: Account,
    },
    get_account: u128,
};
const FuzzOpActionTag = std.meta.Tag(FuzzOpAction);

const FuzzOpModifier = union(enum) {
    normal,
    crash_after_ticks: usize,
};
const FuzzOpModifierTag = std.meta.Tag(FuzzOpModifier);

const FuzzOp = struct {
    action: FuzzOpAction,
    modifier: FuzzOpModifier,
};

const Environment = struct {
    const cluster = 32;
    const replica = 4;
    const replica_count = 6;

    const node_count = 1024;
    // This is the smallest size that set_associative_cache will allow us.
    const cache_entries_max = 2048;
    const forest_options = StateMachine.forest_options(.{
        .lsm_forest_node_count = node_count,
        .cache_entries_accounts = cache_entries_max,
        .cache_entries_transfers = cache_entries_max,
        .cache_entries_posted = cache_entries_max,
    });

    // We must call compact after every 'batch'.
    // Every `lsm_batch_multiple` batches may put/remove `value_count_max` values per index.
    // Every `FuzzOp.put_account` issues one remove and one put per index.
    const puts_since_compact_max = @divTrunc(
        Forest.groove_config.accounts.ObjectTree.Table.value_count_max,
        2 * constants.lsm_batch_multiple,
    );

    const compacts_per_checkpoint = std.math.divCeil(
        usize,
        constants.journal_slot_count,
        constants.lsm_batch_multiple,
    ) catch unreachable;

    const State = enum {
        init,
        superblock_format,
        superblock_open,
        forest_init,
        forest_open,
        fuzzing,
        forest_compact,
        forest_checkpoint,
        superblock_checkpoint,
    };

    state: State,
    storage: *Storage,
    superblock: SuperBlock,
    superblock_context: SuperBlock.Context,
    grid: Grid,
    forest: Forest,
    checkpoint_op: ?u64,
    ticks_remaining: usize,

    fn init(env: *Environment, storage: *Storage) !void {
        env.storage = storage;

        env.superblock = try SuperBlock.init(allocator, .{
            .storage = env.storage,
            .storage_size_limit = constants.storage_size_max,
        });

        env.grid = try Grid.init(allocator, .{
            .superblock = &env.superblock,
            .missing_blocks_max = 0,
            .missing_tables_max = 0,
        });

        env.forest = undefined;
        env.checkpoint_op = null;
        env.ticks_remaining = std.math.maxInt(usize);
    }

    fn deinit(env: *Environment) void {
        env.superblock.deinit(allocator);
        env.grid.deinit(allocator);
    }

    pub fn run(storage: *Storage, fuzz_ops: []const FuzzOp) !void {
        var env: Environment = undefined;
        env.state = .init;
        try env.init(storage);
        defer env.deinit();

        env.change_state(.init, .superblock_format);
        env.superblock.format(superblock_format_callback, &env.superblock_context, .{
            .cluster = cluster,
            .replica = replica,
            .replica_count = replica_count,
        });
        try env.tick_until_state_change(.superblock_format, .superblock_open);

        try env.open();
        defer env.close();

        try env.apply(fuzz_ops);
    }

    fn change_state(env: *Environment, current_state: State, next_state: State) void {
        assert(env.state == current_state);
        env.state = next_state;
    }

    fn tick_until_state_change(env: *Environment, current_state: State, next_state: State) !void {
        while (true) {
            if (env.state != current_state) break;

            if (env.ticks_remaining == 0) return error.OutOfTicks;
            env.ticks_remaining -= 1;
            env.storage.tick();
        }
        assert(env.state == next_state);
    }

    fn open(env: *Environment) !void {
        env.superblock.open(superblock_open_callback, &env.superblock_context);
        try env.tick_until_state_change(.superblock_open, .forest_init);

        env.forest = try Forest.init(allocator, &env.grid, node_count, forest_options);
        env.change_state(.forest_init, .forest_open);
        env.forest.open(forest_open_callback);

        try env.tick_until_state_change(.forest_open, .fuzzing);
    }

    fn close(env: *Environment) void {
        env.forest.deinit(allocator);
    }

    fn superblock_format_callback(superblock_context: *SuperBlock.Context) void {
        const env = @fieldParentPtr(@This(), "superblock_context", superblock_context);
        env.change_state(.superblock_format, .superblock_open);
    }

    fn superblock_open_callback(superblock_context: *SuperBlock.Context) void {
        const env = @fieldParentPtr(@This(), "superblock_context", superblock_context);
        env.change_state(.superblock_open, .forest_init);
    }

    fn forest_open_callback(forest: *Forest) void {
        const env = @fieldParentPtr(@This(), "forest", forest);
        env.change_state(.forest_open, .fuzzing);
    }

    pub fn compact(env: *Environment, op: u64) !void {
        env.change_state(.fuzzing, .forest_compact);
        env.forest.compact(forest_compact_callback, op);
        try env.tick_until_state_change(.forest_compact, .fuzzing);
    }

    fn forest_compact_callback(forest: *Forest) void {
        const env = @fieldParentPtr(@This(), "forest", forest);
        env.change_state(.forest_compact, .fuzzing);
    }

    pub fn checkpoint(env: *Environment, op: u64) !void {
        assert(env.checkpoint_op == null);
        env.checkpoint_op = op - constants.lsm_batch_multiple;

        env.change_state(.fuzzing, .forest_checkpoint);
        env.forest.checkpoint(forest_checkpoint_callback);
        try env.tick_until_state_change(.forest_checkpoint, .superblock_checkpoint);
        try env.tick_until_state_change(.superblock_checkpoint, .fuzzing);
    }

    fn forest_checkpoint_callback(forest: *Forest) void {
        const env = @fieldParentPtr(@This(), "forest", forest);
        const op = env.checkpoint_op.?;
        env.checkpoint_op = null;

        {
            // VSRState.monotonic() asserts that the previous_checkpoint id changes.
            // In a normal replica this is guaranteed – even if the LSM is idle and no blocks
            // are acquired or released, the client sessions are necessarily mutated.
            var reply = std.mem.zeroInit(vsr.Header, .{
                .cluster = cluster,
                .command = .reply,
                .op = op,
                .commit = op,
            });
            reply.set_checksum_body(&.{});
            reply.set_checksum();

            _ = env.superblock.client_sessions.put(1, &reply);
        }

        env.change_state(.forest_checkpoint, .superblock_checkpoint);
        env.superblock.checkpoint(superblock_checkpoint_callback, &env.superblock_context, .{
            .commit_min_checksum = env.superblock.working.vsr_state.commit_min_checksum + 1,
            .commit_min = op,
            .commit_max = op + 1,
            .sync_op_min = 0,
            .sync_op_max = 0,
        });
    }

    fn superblock_checkpoint_callback(superblock_context: *SuperBlock.Context) void {
        const env = @fieldParentPtr(@This(), "superblock_context", superblock_context);
        env.change_state(.superblock_checkpoint, .fuzzing);
    }

    fn prefetch_account(env: *Environment, id: u128) !void {
        const groove_accounts = &env.forest.grooves.accounts;

        const GrooveAccounts = @TypeOf(groove_accounts.*);

        const Getter = struct {
            _id: u128,
            _groove_accounts: *GrooveAccounts,

            finished: bool = false,
            prefetch_context: GrooveAccounts.PrefetchContext = undefined,

            fn prefetch_start(getter: *@This()) void {
                const groove = getter._groove_accounts;
                groove.prefetch_setup(null);
                groove.prefetch_enqueue(getter._id);
                groove.prefetch(@This().prefetch_callback, &getter.prefetch_context);
            }

            fn prefetch_callback(prefetch_context: *GrooveAccounts.PrefetchContext) void {
                const getter = @fieldParentPtr(@This(), "prefetch_context", prefetch_context);
                assert(!getter.finished);
                getter.finished = true;
            }
        };

        var getter = Getter{
            ._id = id,
            ._groove_accounts = groove_accounts,
        };
        getter.prefetch_start();
        while (!getter.finished) {
            if (env.ticks_remaining == 0) return error.OutOfTicks;
            env.ticks_remaining -= 1;
            env.storage.tick();
        }
    }

    fn put_account(env: *Environment, a: *const Account) void {
        env.forest.grooves.accounts.upsert(a);
    }

    fn get_account(env: *Environment, id: u128) ?Account {
        const account = env.forest.grooves.accounts.get(id) orelse return null;
        return account.*;
    }

    // The forest should behave like a simple key-value data-structure.
    const Model = struct {
        checkpointed: KVType, // represents persistent state
        log: LogType, // represents in-memory state

        const KVType = std.hash_map.AutoHashMap(u128, Account);
        const LogEntry = struct { op: u64, account: Account };
        const LogType = std.fifo.LinearFifo(LogEntry, .Dynamic);

        pub fn init() Model {
            return .{
                .checkpointed = KVType.init(allocator),
                .log = LogType.init(allocator),
            };
        }

        pub fn deinit(model: *Model) void {
            model.checkpointed.deinit();
            model.log.deinit();
        }

        pub fn put_account(model: *Model, account: *const Account, op: u64) !void {
            try model.log.writeItem(.{ .op = op, .account = account.* });
        }

        pub fn get_account(model: *const Model, id: u128) ?Account {
            var latest_op: ?u64 = null;
            const log_size = model.log.readableLength();
            var log_left = log_size;
            while (log_left > 0) : (log_left -= 1) {
                const entry = model.log.peekItem(log_left - 1); // most recent first
                if (latest_op == null) {
                    latest_op = entry.op;
                }

                assert(latest_op.? >= entry.op);

                if (entry.account.id == id) {
                    return entry.account;
                }
            }
            return model.checkpointed.get(id);
        }

        pub fn checkpoint(model: *Model, op: u64) !void {
            const checkpointable = op - (op % constants.lsm_batch_multiple) -| 1;
            const log_size = model.log.readableLength();
            var log_index: usize = 0;
            while (log_index < log_size) : (log_index += 1) {
                const entry = model.log.peekItem(log_index);
                if (entry.op > checkpointable) {
                    break;
                }

                try model.checkpointed.put(entry.account.id, entry.account);
            }
            model.log.discard(log_index);
        }

        pub fn storage_reset(model: *Model) void {
            model.log.discard(model.log.readableLength());
        }
    };

    fn apply(env: *Environment, fuzz_ops: []const FuzzOp) !void {
        var model = Model.init();
        defer model.deinit();

        for (fuzz_ops, 0..) |fuzz_op, fuzz_op_index| {
            assert(env.state == .fuzzing);
            log.debug("Running fuzz_ops[{}/{}] == {}", .{ fuzz_op_index, fuzz_ops.len, fuzz_op.action });

            const storage_size_used = env.storage.size_used();
            log.debug("storage.size_used = {}/{}", .{ storage_size_used, env.storage.size });

            const model_size = (model.log.readableLength() + model.checkpointed.count()) * @sizeOf(Account);
            // NOTE: This isn't accurate anymore because the model can contain multiple copies of an account in the log
            log.debug("space_amplification ~= {d:.2}", .{
                @as(f64, @floatFromInt(storage_size_used)) / @as(f64, @floatFromInt(model_size)),
            });

            // Apply fuzz_op to the forest and the model.
            try env.apply_op(fuzz_op, &model);
        }

        log.debug("Applied all ops", .{});
    }

    fn apply_op(env: *Environment, fuzz_op: FuzzOp, model: *Model) !void {
        switch (fuzz_op.modifier) {
            .normal => {
                env.ticks_remaining = std.math.maxInt(usize);
                env.apply_op_action(fuzz_op.action, model) catch |err| {
                    switch (err) {
                        error.OutOfTicks => unreachable,
                        else => return err,
                    }
                };
            },
            .crash_after_ticks => |ticks_remaining| {
                env.ticks_remaining = ticks_remaining;
                env.apply_op_action(fuzz_op.action, model) catch |err| {
                    switch (err) {
                        error.OutOfTicks => {},
                        else => return err,
                    }
                };
                env.ticks_remaining = std.math.maxInt(usize);

                env.storage.log_pending_io();
                env.close();
                env.deinit();
                env.storage.reset();

                env.state = .init;
                try env.init(env.storage);

                env.change_state(.init, .superblock_open);
                try env.open();

                // TODO: currently this checks that everything added to the LSM after checkpoint
                // resets to the last checkpoint on crash by looking through what's been added
                // afterwards. This won't work if we add account removal to the fuzzer though.
                const log_size = model.log.readableLength();
                var log_index: usize = 0;
                while (log_index < log_size) : (log_index += 1) {
                    const entry = model.log.peekItem(log_index);
                    const id = entry.account.id;
                    if (model.checkpointed.get(id)) |checkpointed_account| {
                        try env.prefetch_account(id);
                        if (env.get_account(id)) |lsm_account| {
                            assert(std.mem.eql(
                                u8,
                                std.mem.asBytes(&lsm_account),
                                std.mem.asBytes(&checkpointed_account),
                            ));
                        } else {
                            std.debug.panic("Account checkpointed but not in lsm after crash.\n {}\n", .{checkpointed_account});
                        }

                        // There are strict limits around how many values can be prefetched by one
                        // commit, see `map_value_count_max` in groove.zig. Thus, we need to make
                        // sure we manually call groove.objects_cache.compact() every
                        // `map_value_count_max` operations here. This is specific to this fuzzing
                        // code.
                        const groove_map_value_count_max =
                            env.forest.grooves.accounts.objects_cache.options.map_value_count_max;

                        if (log_index % groove_map_value_count_max == 0) {
                            env.forest.grooves.accounts_immutable.objects_cache.compact();
                            env.forest.grooves.accounts_mutable.objects_cache.compact();
                        }
                    }
                }
                model.storage_reset();
            },
        }
    }

    fn apply_op_action(env: *Environment, fuzz_op_action: FuzzOpAction, model: *Model) !void {
        switch (fuzz_op_action) {
            .compact => |c| {
                try env.compact(c.op);
                if (c.checkpoint) {
                    try model.checkpoint(c.op);
                    try env.checkpoint(c.op);
                }
            },
            .put_account => |put| {
                // The forest requires prefetch before put.
                try env.prefetch_account(put.account.id);
                env.put_account(&put.account);
                try model.put_account(&put.account, put.op);
            },
            .get_account => |id| {
                // Get account from lsm.
                try env.prefetch_account(id);
                const lsm_account = env.get_account(id);

                // Compare result to model.
                const model_account = model.get_account(id);
                if (model_account == null) {
                    assert(lsm_account == null);
                } else {
                    assert(std.mem.eql(
                        u8,
                        std.mem.asBytes(&model_account.?),
                        std.mem.asBytes(&lsm_account.?),
                    ));
                }
            },
        }
    }
};

pub fn run_fuzz_ops(storage_options: Storage.Options, fuzz_ops: []const FuzzOp) !void {
    // Init mocked storage.
    var storage = try Storage.init(allocator, constants.storage_size_max, storage_options);
    defer storage.deinit(allocator);

    try Environment.run(&storage, fuzz_ops);
}

fn random_id(random: std.rand.Random, comptime Int: type) Int {
    // We have two opposing desires for random ids:
    const avg_int: Int = if (random.boolean())
        // 1. We want to cause many collisions.
        8
    else
        // 2. We want to generate enough ids that the cache can't hold them all.
        Environment.cache_entries_max;
    return fuzz.random_int_exponential(random, Int, avg_int);
}

pub fn generate_fuzz_ops(random: std.rand.Random, fuzz_op_count: usize) ![]const FuzzOp {
    log.info("fuzz_op_count = {}", .{fuzz_op_count});

    const fuzz_ops = try allocator.alloc(FuzzOp, fuzz_op_count);
    errdefer allocator.free(fuzz_ops);

    const action_distribution = fuzz.Distribution(FuzzOpActionTag){
        // Maybe compact more often than forced to by `puts_since_compact`.
        .compact = if (random.boolean()) 0 else 1,
        // Always do puts.
        .put_account = constants.lsm_batch_multiple * 2,
        // Maybe do some gets.
        .get_account = if (random.boolean()) 0 else constants.lsm_batch_multiple,
    };
    log.info("action_distribution = {:.2}", .{action_distribution});

    const modifier_distribution = fuzz.Distribution(FuzzOpModifierTag){
        .normal = 1,
        // Maybe crash and recover from the last checkpoint a few times per fuzzer run.
        .crash_after_ticks = if (random.boolean()) 0 else 1E-2,
    };
    log.info("modifier_distribution = {:.2}", .{modifier_distribution});

    log.info("puts_since_compact_max = {}", .{Environment.puts_since_compact_max});
    log.info("compacts_per_checkpoint = {}", .{Environment.compacts_per_checkpoint});

    var id_to_account = std.hash_map.AutoHashMap(u128, Account).init(allocator);
    defer id_to_account.deinit();

    var op: u64 = 1;
    var persisted_op: u64 = op;
    var puts_since_compact: usize = 0;
    for (fuzz_ops, 0..) |*fuzz_op, fuzz_op_index| {
        const action_tag: FuzzOpActionTag = if (puts_since_compact >= Environment.puts_since_compact_max)
            // We have to compact before doing any other operations.
            .compact
        else
            // Otherwise pick a random FuzzOp.
            fuzz.random_enum(random, FuzzOpActionTag, action_distribution);
        const action = switch (action_tag) {
            .compact => compact: {
                const compact_op = op;
                op += 1;
                const checkpoint =
                    // Can only checkpoint on the last beat of the bar.
                    compact_op % constants.lsm_batch_multiple == constants.lsm_batch_multiple - 1 and
                    compact_op > constants.lsm_batch_multiple and
                    // Never checkpoint at the same op twice
                    compact_op > persisted_op + constants.lsm_batch_multiple and
                    // Checkpoint at roughly the same rate as log wraparound.
                    random.uintLessThan(usize, Environment.compacts_per_checkpoint) == 0;
                if (checkpoint) {
                    persisted_op = op - constants.lsm_batch_multiple;
                }
                break :compact FuzzOpAction{
                    .compact = .{
                        .op = compact_op,
                        .checkpoint = checkpoint,
                    },
                };
            },
            .put_account => put_account: {
                const id = random_id(random, u128);
                var account = id_to_account.get(id) orelse Account{
                    .id = id,
                    // `timestamp` must be unique.
                    .timestamp = fuzz_op_index,
                    .user_data_128 = random_id(random, u128),
                    .user_data_64 = random_id(random, u64),
                    .user_data_32 = random_id(random, u32),
                    .reserved = 0,
                    .ledger = random_id(random, u32),
                    .code = random_id(random, u16),
                    .flags = .{
                        .debits_must_not_exceed_credits = random.boolean(),
                        .credits_must_not_exceed_debits = random.boolean(),
                    },
                    .debits_pending = 0,
                    .debits_posted = 0,
                    .credits_pending = 0,
                    .credits_posted = 0,
                };

                // These are the only fields we are allowed to change on existing accounts.
                account.debits_pending = random.int(u64);
                account.debits_posted = random.int(u64);
                account.credits_pending = random.int(u64);
                account.credits_posted = random.int(u64);

                try id_to_account.put(account.id, account);
                break :put_account FuzzOpAction{ .put_account = .{
                    .op = op,
                    .account = account,
                } };
            },
            .get_account => FuzzOpAction{ .get_account = random_id(random, u128) },
        };
        switch (action) {
            .compact => puts_since_compact = 0,
            .put_account => puts_since_compact += 1,
            .get_account => {},
        }
        // TODO(jamii)
        // Currently, crashing is only interesting during a compact.
        // But once we have concurrent compaction, crashing at any point can be interesting.
        //
        // TODO(jamii)
        // If we crash during a checkpoint, on restart we should either:
        // * See the state from that checkpoint.
        // * See the state from the previous checkpoint.
        // But this is difficult to test, so for now we'll avoid it.
        const modifer_tag = if (action == .compact and !action.compact.checkpoint)
            fuzz.random_enum(
                random,
                FuzzOpModifierTag,
                modifier_distribution,
            )
        else
            FuzzOpModifierTag.normal;
        const modifier = switch (modifer_tag) {
            .normal => FuzzOpModifier{ .normal = {} },
            .crash_after_ticks => FuzzOpModifier{
                .crash_after_ticks = fuzz.random_int_exponential(random, usize, io_latency_mean),
            },
        };
        switch (modifier) {
            .normal => {},
            .crash_after_ticks => op = persisted_op,
        }
        fuzz_op.* = .{
            .action = action,
            .modifier = modifier,
        };
    }

    return fuzz_ops;
}

const io_latency_mean = 20;

pub fn main() !void {
    try tracer.init(allocator);
    defer tracer.deinit(allocator);

    const fuzz_args = try fuzz.parse_fuzz_args(allocator);
    var rng = std.rand.DefaultPrng.init(fuzz_args.seed);
    const random = rng.random();

    const fuzz_op_count = @min(
        fuzz_args.events_max orelse @as(usize, 1E7),
        fuzz.random_int_exponential(random, usize, 1E6),
    );

    const fuzz_ops = try generate_fuzz_ops(random, fuzz_op_count);
    defer allocator.free(fuzz_ops);

    try run_fuzz_ops(Storage.Options{
        .seed = random.int(u64),
        .read_latency_min = 0,
        .read_latency_mean = 0 + fuzz.random_int_exponential(random, u64, io_latency_mean),
        .write_latency_min = 0,
        .write_latency_mean = 0 + fuzz.random_int_exponential(random, u64, io_latency_mean),
        // We can't actually recover from a crash in this fuzzer since we would need
        // to transfer state from a different replica to continue.
        .crash_fault_probability = 0,
    }, fuzz_ops);

    log.info("Passed!", .{});
}
