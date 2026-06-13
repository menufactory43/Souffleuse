"""LLDB callback for Cotypist's branch-pruning function."""

import lldb


PRUNE_FILE_ADDRESS = 0x100318238


def _read_u64(process, address):
    error = lldb.SBError()
    value = process.ReadUnsignedFromMemory(address, 8, error)
    return value if error.Success() else None


def _array_count(process, variable_address):
    storage = _read_u64(process, variable_address)
    if not storage:
        return None
    return _read_u64(process, storage + 0x10)


def _on_prune(frame, _breakpoint_location, _internal_dict):
    process = frame.GetThread().GetProcess()
    active_count = _array_count(
        process,
        frame.FindRegister("x1").GetValueAsUnsigned(),
    )
    completed_count = _array_count(
        process,
        frame.FindRegister("x0").GetValueAsUnsigned(),
    )
    width = frame.FindRegister("x5").GetValueAsUnsigned()
    metric_mode = frame.FindRegister("x6").GetValueAsUnsigned() & 0xFF
    aggregation_mode = frame.FindRegister("x7").GetValueAsUnsigned() & 0xFF
    print(
        "COTYPIST_PRUNE"
        f" k={width}"
        f" active={active_count}"
        f" completed={completed_count}"
        f" metric_mode={metric_mode}"
        f" aggregation_mode={aggregation_mode}",
        flush=True,
    )
    return False


def __lldb_init_module(debugger, _internal_dict):
    target = debugger.GetSelectedTarget()
    module = target.GetModuleAtIndex(0)
    address = module.ResolveFileAddress(PRUNE_FILE_ADDRESS)
    breakpoint = target.BreakpointCreateBySBAddress(address)
    breakpoint.SetScriptCallbackFunction(
        "lldb_branch_width._on_prune",
    )
    print(
        "COTYPIST_PRUNE_BREAKPOINT"
        f" address=0x{address.GetFileAddress():x}"
        f" locations={breakpoint.GetNumLocations()}",
        flush=True,
    )
