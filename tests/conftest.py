"""
Pytest configuration.

The Durable Execution SDK only exists inside Lambda; we stub it here before
loading any handler module so that imports succeed locally.  Each handler is
loaded once with a unique sys.modules key to avoid name collisions (all three
files are named handler.py).
"""

import functools
import importlib.util
import os
import sys
from unittest.mock import MagicMock

# ── Stub the Durable Execution SDK ───────────────────────────────────────────

def _durable_step(fn):
    """
    Test stand-in for @durable_step.

    In production: fn(args) → deferred; context.step(deferred) → result.
    In tests:      fn(args) → thunk; thunk(ctx) → fn(ctx, args).
    The original function is stored on .__original__ for direct unit testing.
    """
    @functools.wraps(fn)
    def step_call(*args, **kwargs):
        def execute(ctx):
            return fn(ctx, *args, **kwargs)
        return execute
    step_call.__original__ = fn
    return step_call


_mock_sdk = MagicMock()
_mock_sdk.durable_step = _durable_step
_mock_sdk.durable_execution = lambda f: f  # handler passes through unchanged
_mock_sdk.DurableContext = MagicMock
_mock_sdk.StepContext = MagicMock
sys.modules["aws_durable_execution_sdk_python"] = _mock_sdk

# ── Load each handler under a unique module name ──────────────────────────────

_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))


def _load(name: str, rel: str):
    path = os.path.join(_ROOT, rel)
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


_load("orchestrator_handler", "src/orchestrator/handler.py")
_load("submission_handler", "src/submission/handler.py")
_load("reviewer_callback_handler", "src/reviewer_callback/handler.py")
_load("status_handler", "src/status/handler.py")
