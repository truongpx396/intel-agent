"""Port conformance suites — PUBLIC API, imported by host repositories.

Contract: specs/001-agent-runtime/contracts/agent-deps.md § Conformance
Tasks:    specs/001-agent-runtime/tasks.md, Stage 2 (T005-T012)

A host proves its integration by subclassing these and binding its own
implementation::

    from intel_agent.conformance import RetrievalServiceContract

    class TestMyRetrieval(RetrievalServiceContract):
        impl = MyRetrievalService

Run them in YOUR CI, against YOUR implementations. A green smoke test with a red
conformance suite means the runtime is working by accident.

WHY THIS LIVES IN THE SHIPPED PACKAGE, NOT IN tests/
    Because a host imports it. Putting it under tests/ would leave it out of the
    wheel and make the cross-repo drift check unshippable -- which would reduce
    "we prove reuse" back to "we assert reuse".

STATUS: skeleton. The suites declare their obligations and are collected by
pytest, but each is marked ``xfail(strict)`` until its Stage-2 task lands. Strict
xfail means an accidentally-passing stub FAILS the build, so this file can never
be mistaken for working coverage.
"""

from __future__ import annotations

from typing import Any, ClassVar

import pytest

__all__ = [
    "AccessFloorContract",
    "ApprovalContract",
    "MeterContract",
    "PolicyContract",
    "RetrievalServiceContract",
    "ToolRegistryContract",
]

_PENDING = "conformance body pending — see specs/001-agent-runtime/tasks.md Stage 2"


class _Contract:
    """Base for every port suite.

    A subclass MUST bind ``impl``. The unbound check is a real, running assertion
    even in the skeleton: it catches the most common integration mistake (declaring
    a suite and forgetting to bind anything) before any port body exists.
    """

    impl: ClassVar[Any] = None

    def test_impl_is_bound(self) -> None:
        assert self.impl is not None, (
            f"{type(self).__name__} must bind `impl` to the implementation under test"
        )


class RetrievalServiceContract(_Contract):
    """T005 — every RetrievalService backend MUST pass this."""

    @pytest.mark.xfail(reason=_PENDING, strict=True)
    def test_predicate_is_a_prefilter_not_a_postfilter(self) -> None:
        """The store must never RETURN a row the caller may not see.

        Asserted by instrumenting the backend's query and inspecting what came back
        from the store, not what survived in Python -- a post-filter produces an
        identical response and is still a breach.
        """
        raise NotImplementedError(_PENDING)

    @pytest.mark.xfail(reason=_PENDING, strict=True)
    def test_empty_result_is_not_an_error(self) -> None:
        """`source_count == 0` is a valid answer state; raising turns it into a failed run."""
        raise NotImplementedError(_PENDING)

    @pytest.mark.xfail(reason=_PENDING, strict=True)
    def test_doc_ids_narrows_and_never_widens(self) -> None:
        """Scoping to a document the caller cannot read returns nothing, not that document."""
        raise NotImplementedError(_PENDING)

    @pytest.mark.xfail(reason=_PENDING, strict=True)
    def test_cross_tenant_row_is_not_found(self) -> None:
        raise NotImplementedError(_PENDING)


class ToolRegistryContract(_Contract):
    """T006 — every ToolRegistry binding (inprocess, mcp_client) MUST pass this."""

    @pytest.mark.xfail(reason=_PENDING, strict=True)
    def test_allowlist_is_enforced_on_every_dispatch(self) -> None:
        raise NotImplementedError(_PENDING)

    @pytest.mark.xfail(reason=_PENDING, strict=True)
    def test_exactly_one_audit_entry_per_call_including_failures(self) -> None:
        """A tool that raises still owes an audit row. Zero rows on the failure path is
        how an attacker's probe becomes invisible."""
        raise NotImplementedError(_PENDING)

    @pytest.mark.xfail(reason=_PENDING, strict=True)
    def test_inprocess_and_remote_paths_are_indistinguishable(self) -> None:
        """Same result, same audit entry. Enforcement lives in the shared wrapper, so
        the transport must not be observable in the outcome."""
        raise NotImplementedError(_PENDING)


class PolicyContract(_Contract):
    """T007 — every Policy MUST pass this."""

    @pytest.mark.xfail(reason=_PENDING, strict=True)
    def test_is_pure(self) -> None:
        """Same input, same decision, across repeated calls. No I/O, no clock, no
        randomness -- an impure Policy can fail open on a network blip."""
        raise NotImplementedError(_PENDING)

    @pytest.mark.xfail(reason=_PENDING, strict=True)
    def test_unknown_action_is_denied(self) -> None:
        """Fail closed. An unrecognized action is not an unconstrained one."""
        raise NotImplementedError(_PENDING)


class MeterContract(_Contract):
    """T008 — every Meter MUST pass this."""

    @pytest.mark.xfail(reason=_PENDING, strict=True)
    def test_idempotency_key_is_honored(self) -> None:
        """Redelivery is normal; the runtime cannot promise exactly-once. A host that
        ignores idem_key will double-charge."""
        raise NotImplementedError(_PENDING)

    @pytest.mark.xfail(reason=_PENDING, strict=True)
    def test_refused_paused_and_rejected_runs_spend_zero(self) -> None:
        raise NotImplementedError(_PENDING)


class ApprovalContract(_Contract):
    """T009 — every ApprovalStore MUST pass this."""

    @pytest.mark.xfail(reason=_PENDING, strict=True)
    def test_pending_gate_spends_nothing_and_mutates_nothing(self) -> None:
        raise NotImplementedError(_PENDING)

    @pytest.mark.xfail(reason=_PENDING, strict=True)
    def test_first_decision_wins_and_resolution_is_idempotent(self) -> None:
        raise NotImplementedError(_PENDING)

    @pytest.mark.xfail(reason=_PENDING, strict=True)
    def test_gate_is_visible_only_to_its_approver(self) -> None:
        raise NotImplementedError(_PENDING)

    @pytest.mark.xfail(reason=_PENDING, strict=True)
    def test_decision_is_never_derived_from_model_output(self) -> None:
        raise NotImplementedError(_PENDING)


class AccessFloorContract(_Contract):
    """T010 — the load-bearing suite (SC-A01, SC-A02).

    This one is different in kind from the others. It is the suite that must pass
    UNCHANGED under both the two-store (RLS + vector pre-filter) and single-store
    (RLS-only) lowerings, from one body with no profile-specific branches.

    If this suite ever needs a branch on which profile is wired, the boundary is
    wrong -- not the test. Resist the branch.
    """

    policy: ClassVar[Any] = None

    def test_policy_is_bound(self) -> None:
        assert self.policy is not None, (
            f"{type(self).__name__} must bind `policy` alongside `impl`"
        )

    @pytest.mark.xfail(reason=_PENDING, strict=True)
    def test_above_clearance_row_is_not_found(self) -> None:
        raise NotImplementedError(_PENDING)

    @pytest.mark.xfail(reason=_PENDING, strict=True)
    def test_cross_tenant_row_is_not_found(self) -> None:
        raise NotImplementedError(_PENDING)

    @pytest.mark.xfail(reason=_PENDING, strict=True)
    def test_manifest_cannot_widen_visibility(self) -> None:
        """A manifest listing a broader tool set surfaces no additional row.
        SC-A01 is a deps/floor property, never a manifest property."""
        raise NotImplementedError(_PENDING)

    @pytest.mark.xfail(reason=_PENDING, strict=True)
    def test_demotion_takes_effect_on_the_next_turn(self) -> None:
        """Memory recalled after a clearance demotion is re-filtered, not replayed."""
        raise NotImplementedError(_PENDING)
