from __future__ import annotations
from typing import Any

CONTRACT_ID = "synergy.economy.bridge-health/v1"
AUTHORITY = "bridge_solvency_telemetry"


def bridge_health_payload(
    *,
    observation_id: str,
    locked_usdc: int,
    locked_eth: int,
    minted_usds: int,
    minted_eths: int,
    health_factor_bps: int,
    emergency_stopped: bool,
    source_chain: str = "Base",
) -> dict[str, Any]:
    if not observation_id.strip():
        raise ValueError("observation_id required")
    values = [locked_usdc, locked_eth, minted_usds, minted_eths, health_factor_bps]
    if any(int(v) < 0 for v in values):
        raise ValueError("bridge telemetry cannot be negative")
    status = (
        "EMERGENCY_STOP"
        if emergency_stopped
        else "HEALTHY"
        if int(health_factor_bps) >= 15000
        else "BELOW_TARGET"
    )
    return {
        "observation_id": observation_id,
        "source_chain": source_chain,
        "locked_usdc": int(locked_usdc),
        "locked_eth": int(locked_eth),
        "minted_usds": int(minted_usds),
        "minted_eths": int(minted_eths),
        "health_factor_bps": int(health_factor_bps),
        "emergency_stopped": bool(emergency_stopped),
        "status": status,
        "execution_authorization": False,
        "accounting_authority": False,
    }
