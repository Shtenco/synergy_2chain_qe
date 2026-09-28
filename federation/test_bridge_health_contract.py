from bridge_health_contract import CONTRACT_ID, bridge_health_payload

def test_bridge_health_is_telemetry_only():
    p=bridge_health_payload(
        observation_id="b1",locked_usdc=1000,locked_eth=1,
        minted_usds=900,minted_eths=1,health_factor_bps=18000,emergency_stopped=False
    )
    assert CONTRACT_ID=="synergy.economy.bridge-health/v1"
    assert p["status"]=="HEALTHY"
    assert p["execution_authorization"] is False
    assert p["accounting_authority"] is False
