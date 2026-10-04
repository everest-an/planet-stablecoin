import "@acton/testing/expect"
import "@acton/emulation/testing"
import "@acton/emulation/network"
import "@acton/crypto"
import "@wrappers/PlanetCore.gen"
import "@contracts/oracle_state"
import "@contracts/limits"
import "@contracts/signed_price"

// Signed price updates: an off-chain relayer/adapter signs a PricePayload; PlanetCore
// verifies it on-chain (isSignatureValid) against the registered signer key. This is
// how a real data source (RedStone/DIA bridge) plugs in — only a public key is needed.
// See docs/oracle-ton.md.

fun deployCoreSigned(): (PlanetCore, Treasury, Treasury) {
    val deployer = testing.treasury("deployer");
    val relayer = testing.treasury("relayer");
    val core = PlanetCore.fromStorage({
        owner: deployer.address,
        jettonMinter: deployer.address,
        totalReserve: 0,
        totalSupply: 0,
        currentPpi: 1000000,
        feesToBurn: 0,
        feesToReserve: 0,
        feesToStaking: 0,
        paused: false,
        assets: [],
        cams: [],
        assetCount: 0,
        baseLocked: false,
        oracleState: OracleState { oracle: deployer.address, signerKey: 0, lastOracleUpdate: 0 }.toCell(),
        limitsState: Limits { maxPerTx: 0, arbRebateBps: 0 }.toCell(),
    });
    expect(core.deploy(deployer.address, { value: ton("0.3") }))
        .toHaveSuccessfulDeploy({ to: core.address });
    return (core, deployer, relayer);
}

get fun `test owner can set signer key`() {
    val (core, deployer, _) = deployCoreSigned();
    val kp = crypto.createMnemonic().toKeyPair();
    core.sendSetSigner(deployer.address, 0, kp.publicKey as uint256, { value: ton("0.05") });
    expect(core.signerKey()).toEqual(kp.publicKey);
}

get fun `test non-owner cannot set signer key`() {
    val (core, _, relayer) = deployCoreSigned();
    val kp = crypto.createMnemonic().toKeyPair();
    val res = core.sendSetSigner(relayer.address, 0, kp.publicKey as uint256, { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: relayer.address, to: core.address, exitCode: 101 });
}

get fun `test signed price update is verified and applied`() {
    val (core, deployer, relayer) = deployCoreSigned();
    val kp = crypto.createMnemonic().toKeyPair();
    core.sendSetSigner(deployer.address, 0, kp.publicKey as uint256, { value: ton("0.05") });
    core.sendSetBasketAsset(deployer.address, 0, 0, 1000000, 1000000, { value: ton("0.05") });

    val payload = PricePayload {
        queryId: 0,
        index: 0,
        price: 1100000,
        volatility: 0,
        liquidity: 1000000,
        riskState: 0,
        timestamp: 1000,
    }.toCell();
    var sig = crypto.sign(kp.privateKey, payload);
    val sigR = sig.loadUint(256);
    val sigS = sig.loadUint(256);
    core.sendSignedPriceUpdate(relayer.address, sigR, sigS, payload, { value: ton("0.05") });
    expect(core.ppi()).toEqual(1100000);
    expect(core.lastOracleUpdate()).toEqual(1000);
}

get fun `test bad signature is rejected`() {
    val (core, deployer, relayer) = deployCoreSigned();
    val kp = crypto.createMnemonic().toKeyPair();
    val other = crypto.createMnemonic().toKeyPair();
    core.sendSetSigner(deployer.address, 0, kp.publicKey as uint256, { value: ton("0.05") });
    core.sendSetBasketAsset(deployer.address, 0, 0, 1000000, 1000000, { value: ton("0.05") });
    val payload = PricePayload {
        queryId: 0, index: 0, price: 1100000, volatility: 0, liquidity: 1000000, riskState: 0, timestamp: 1000,
    }.toCell();
    var sig = crypto.sign(other.privateKey, payload);
    val sigR = sig.loadUint(256);
    val sigS = sig.loadUint(256);
    val res = core.sendSignedPriceUpdate(relayer.address, sigR, sigS, payload, { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: relayer.address, to: core.address, exitCode: 114 });
}

get fun `test signed update rejected when no signer set`() {
    val (core, deployer, relayer) = deployCoreSigned();
    val kp = crypto.createMnemonic().toKeyPair();
    core.sendSetBasketAsset(deployer.address, 0, 0, 1000000, 1000000, { value: ton("0.05") });
    val payload = PricePayload {
        queryId: 0, index: 0, price: 1100000, volatility: 0, liquidity: 1000000, riskState: 0, timestamp: 1000,
    }.toCell();
    var sig = crypto.sign(kp.privateKey, payload);
    val sigR = sig.loadUint(256);
    val sigS = sig.loadUint(256);
    val res = core.sendSignedPriceUpdate(relayer.address, sigR, sigS, payload, { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: relayer.address, to: core.address, exitCode: 113 });
}
