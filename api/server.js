const http = require('http');
const fs = require('fs');
const path = require('path');
const { Pool } = require('pg');

// Load .env manually to handle special characters properly
const envPath = path.join(__dirname, '.env');
if (fs.existsSync(envPath)) {
  for (const line of fs.readFileSync(envPath, 'utf8').split('\n')) {
    const m = line.match(/^([A-Z_]+)=(.*)$/);
    if (m) process.env[m[1]] = m[2];
  }
}

// DB credentials from environment variables ONLY — never hardcode
const mvpDb = new Pool({
  host: process.env.MVP_DB_HOST || 'localhost',
  port: parseInt(process.env.MVP_DB_PORT || '5435'),
  database: process.env.MVP_DB_NAME || 'dob-prod',
  user: process.env.MVP_DB_USER,
  password: process.env.MVP_DB_PASS,
  max: 5,
  idleTimeoutMillis: 30000,
});

const valDb = new Pool({
  host: process.env.VAL_DB_HOST || 'localhost',
  port: parseInt(process.env.VAL_DB_PORT || '5435'),
  database: process.env.VAL_DB_NAME || 'dob-validator',
  user: process.env.VAL_DB_USER,
  password: process.env.VAL_DB_PASS,
  max: 5,
  idleTimeoutMillis: 30000,
});

const dexDb = new Pool({
  host: process.env.DEX_DB_HOST || process.env.MVP_DB_HOST || '127.0.0.1',
  port: parseInt(process.env.DEX_DB_PORT || process.env.MVP_DB_PORT || '5435'),
  database: process.env.DEX_DB_NAME || 'dob-dex',
  user: process.env.DEX_DB_USER || process.env.MVP_DB_USER,
  password: process.env.DEX_DB_PASS || process.env.MVP_DB_PASS,
  max: 5,
  idleTimeoutMillis: 30000,
});

const PORT = parseInt(process.env.DEX_API_PORT || '3050');

// ── Write protection (R7) ──
// swaps / redeems / lp-events are reported by the browser (app-evm.html trackEvent) right
// after the user's tx is mined, so there is no secret the emitter could hold. Instead every
// write is checked against the chain: the tx must exist, have succeeded, be sent by the
// reported wallet and target one of our contracts. block_number comes from the receipt.
// oracle-updates has no browser caller: it needs DEX_INGEST_TOKEN (Bearer), off if unset.
const CHAIN_RPC = { 1301: process.env.DEX_RPC_1301 || 'https://sepolia.unichain.org' };
const OUR_CONTRACTS = {
  1301: new Set([
    '0x217f355497A67F5ef82cff105Fb14a84C9A9E071', '0x652E5572aF3a879D591a4DD289566bcF28BeA52B',
    '0x5d38b9bD487D8a0ff7997dB953a68F650B242e00', '0xb00Ee936e85B9e0F2f67bd890D545a0E8FCa404F',
    '0x9966a54849979F9d037f797Bc1594731fbd82888', '0x00B036B58a818B1BC34d502D3fE730Db729e62AC',
    '0x7DE1d7FA86045A5fA4D42ACb81C54ec9FF6578Fb', '0x8EBB4B407Eb6365FbFaB9Cf01689a62c24cC7c25',
    '0x9E1aeb6c2f8f17C372D62ECe44792818d8BFb97a', '0x1784CD059E11D3d8eBf25b5daaC183614F772bC0',
    '0xde66Fd2575B92f62b0bcD2F976ea6398C3D06551', '0x1dcB1e529869173AB35064B45e35B26aEdc1B475',
    '0xB48eeFa4Dc3fc9D32E16Ab74cC8f67D220cd33a5', '0x9A46d60CD009150dF71764dA7FadCc1628d6a46A',
    '0x3a1f86B027fDC57558178F066609c8ec039cD457', '0x6a7D84C6f7908132371ed28Bed8f1530E5341D44',
    '0x6C5A6a2294f4680f54Ac76843D22BA806c7d108a', '0xF8D2691F646de6E0E61131C907D2E326Ab3aDa92',
  ].map(a => a.toLowerCase())),
};
const INGEST_TOKEN = process.env.DEX_INGEST_TOKEN || '';

function clientIp(req) {
  const r = req.headers['x-real-ip'];   // set by nginx to $remote_addr
  return (typeof r === 'string' && r) || req.socket.remoteAddress || 'unknown';
}

const buckets = new Map();
// Fixed window per key. Returns 0 when allowed, else seconds to wait.
function hit(key, limit, windowMs) {
  const now = Date.now();
  let b = buckets.get(key);
  if (!b || now >= b.reset) { b = { n: 0, reset: now + windowMs }; buckets.set(key, b); }
  if (buckets.size > 50000) for (const [k, v] of buckets) if (now >= v.reset) buckets.delete(k);
  if (b.n >= limit) return Math.max(1, Math.ceil((b.reset - now) / 1000));
  b.n++;
  return 0;
}
const READ_PER_MIN = parseInt(process.env.RL_READ_PER_MIN || '120');
const WRITE_PER_MIN = parseInt(process.env.RL_WRITE_PER_MIN || '20');

async function rpc(chainId, method, params) {
  const r = await fetch(CHAIN_RPC[chainId], {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
    signal: AbortSignal.timeout(8000),
  });
  const j = await r.json();
  if (j.error) throw new Error(j.error.message || 'rpc error');
  return j.result;
}

// Returns { blockNumber } when the tx is a successful call from `wallet` to our contracts.
async function verifyTx(b) {
  const chainId = Number(b.chainId);
  if (!CHAIN_RPC[chainId]) return { error: 'unsupported chainId' };
  if (typeof b.txHash !== 'string' || !/^0x[0-9a-fA-F]{64}$/.test(b.txHash)) return { error: 'invalid txHash' };
  if (typeof b.wallet !== 'string' || !/^0x[0-9a-fA-F]{40}$/.test(b.wallet)) return { error: 'invalid wallet' };
  let rc = await rpc(chainId, 'eth_getTransactionReceipt', [b.txHash]);
  if (!rc) { await new Promise(r => setTimeout(r, 2000)); rc = await rpc(chainId, 'eth_getTransactionReceipt', [b.txHash]); }
  if (!rc) return { error: 'tx not found' };
  if (rc.status !== '0x1') return { error: 'tx failed' };
  if ((rc.from || '').toLowerCase() !== b.wallet.toLowerCase()) return { error: 'tx sender mismatch' };
  if (!OUR_CONTRACTS[chainId].has((rc.to || '').toLowerCase())) return { error: 'tx not to a DobDex contract' };
  return { blockNumber: parseInt(rc.blockNumber, 16) };
}

function send(res, status, body, extra) {
  res.writeHead(status, extra ? { ...headers, ...extra } : headers);
  res.end(JSON.stringify(body));
}

// CORS headers for the frontend
const headers = {
  'Content-Type': 'application/json',
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Authorization',
};

async function getValidatedPools(networkIds) {
  // 1. Get verified pools from MVP DB with their tokens
  const poolRes = await mvpDb.query(`
    SELECT
      p.address AS pool_address,
      p.name, p.description, p.ticker,
      p.network_id,
      p.participation_token_address,
      p.participation_token_minted,
      p.validator_certificate_hash,
      p.validator_overall_score,
      p.validated_at,
      p.icon_image, p.banner_image,
      t.address AS token_address,
      t.name AS token_name,
      t.symbol AS token_symbol,
      t.icon_url AS token_icon,
      t.decimal AS token_decimals,
      n.name AS network_name,
      n.chain AS network_chain
    FROM pools p
    LEFT JOIN tokens t ON p.token_id = t.id
    LEFT JOIN networks n ON p.network_id = n.id
    WHERE p.is_verified = true
      AND (p.deleted IS NOT TRUE)
      AND (p.is_public = true)
      AND p.network_id = ANY($1::int[])
    ORDER BY p.validated_at DESC
  `, [networkIds]);

  if (!poolRes.rows.length) return [];

  // 2. Get certificate details from Validator DB
  const certHashes = poolRes.rows
    .map(r => r.validator_certificate_hash)
    .filter(Boolean);

  let certs = {};
  if (certHashes.length) {
    const certRes = await valDb.query(`
      SELECT
        c."certificateHash",
        c."overallScore",
        c."status",
        c."issuedAt",
        c."expiresAt",
        c."operatorWallet",
        ar."technicalScore",
        ar."regulatoryScore",
        ar."financialScore",
        ar."environmentalScore",
        ar."certificationLevel",
        ar."riskAssessment",
        s."deviceName",
        s."deviceType",
        s."manufacturer",
        s."model",
        s."location"
      FROM certificates c
      LEFT JOIN admin_reviews ar ON c."adminReviewId" = ar.id
      LEFT JOIN submissions s ON c."submissionId" = s.id
      WHERE c."certificateHash" = ANY($1::text[])
        AND c."status" = 'ACTIVE'
    `, [certHashes]);

    for (const c of certRes.rows) {
      certs[c.certificateHash] = c;
    }
  }

  // 3. Merge pool + validation data
  return poolRes.rows.map(p => {
    const cert = certs[p.validator_certificate_hash] || null;
    return {
      poolAddress: p.pool_address,
      name: p.name,
      description: p.description,
      ticker: p.ticker,
      networkId: p.network_id,
      networkName: p.network_name,
      tokenAddress: p.participation_token_address || p.token_address,
      tokenSymbol: p.token_symbol || p.ticker,
      tokenName: p.token_name || p.name,
      tokenIcon: p.token_icon || p.icon_image,
      tokenDecimals: p.token_decimals || 18,
      tokensMinted: p.participation_token_minted,
      validatedAt: p.validated_at,
      overallScore: p.validator_overall_score,
      certificate: cert ? {
        hash: cert.certificateHash,
        status: cert.status,
        overallScore: cert.overallScore,
        issuedAt: cert.issuedAt,
        expiresAt: cert.expiresAt,
        scores: {
          technical: cert.technicalScore,
          regulatory: cert.regulatoryScore,
          financial: cert.financialScore,
          environmental: cert.environmentalScore,
        },
        certificationLevel: cert.certificationLevel,
        riskAssessment: cert.riskAssessment,
        device: {
          name: cert.deviceName,
          type: cert.deviceType,
          manufacturer: cert.manufacturer,
          model: cert.model,
          location: cert.location,
        },
      } : null,
    };
  });
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let data = '';
    req.on('data', c => { data += c; if (data.length > 64e3) { reject(new Error('Too large')); req.destroy(); } });
    req.on('end', () => { try { resolve(JSON.parse(data)); } catch { reject(new Error('Invalid JSON')); } });
  });
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://localhost:${PORT}`);

  if (req.method === 'OPTIONS') {
    res.writeHead(204, headers);
    res.end();
    return;
  }

  const ip = clientIp(req);
  const isWrite = req.method === 'POST';
  const wait = isWrite ? hit('w:' + ip, WRITE_PER_MIN, 60e3) : hit('r:' + ip, READ_PER_MIN, 60e3);
  if (wait) return send(res, 429, { error: 'rate_limited', retry_after: wait }, { 'Retry-After': String(wait) });

  // Tx-backed writes: verify on-chain before touching the DB.
  if (isWrite && ['/api/swaps', '/api/redeems', '/api/lp-events'].includes(url.pathname)) {
    let b;
    try { b = await readBody(req); } catch (e) { return send(res, 400, { error: e.message }); }
    const num = v => v !== '' && v !== null && Number.isFinite(Number(v));
    const need = { '/api/swaps': ['amountIn', 'amountOut'], '/api/redeems': ['dusdcAmount', 'usdcAmount'], '/api/lp-events': ['amount'] }[url.pathname];
    if (!b || typeof b !== 'object' || need.some(k => !num(b[k]))) return send(res, 400, { error: 'missing or non-numeric ' + need.join('/') });
    if (url.pathname === '/api/swaps' && !['buy', 'sell'].includes(b.direction)) return send(res, 400, { error: 'direction must be buy|sell' });
    for (const k of ['tokenId', 'eventType']) if (b[k] != null) b[k] = String(b[k]).slice(0, 32);
    try {
      const v = await verifyTx(b);
      if (v.error) return send(res, 422, { error: v.error });
      b.blockNumber = v.blockNumber;
      b.chainId = Number(b.chainId);
      b.wallet = b.wallet.toLowerCase();
    } catch (e) {
      console.error('verifyTx error:', e.message);
      return send(res, 503, { error: 'chain verification unavailable' }, { 'Retry-After': '30' });
    }
    req.verifiedBody = b;
  }
  if (isWrite && url.pathname === '/api/oracle-updates') {
    const auth = req.headers.authorization || '';
    if (!INGEST_TOKEN || auth !== 'Bearer ' + INGEST_TOKEN) return send(res, 401, { error: 'unauthorized' });
  }

  // ── Validated pools (from MVP + Validator DBs) ──
  if (req.method === 'GET' && url.pathname === '/api/validated-pools') {
    try {
      const networks = (url.searchParams.get('networks') || '1301')
        .split(',').map(Number).filter(Boolean);
      const pools = await getValidatedPools(networks);
      res.writeHead(200, headers);
      res.end(JSON.stringify({ pools }));
    } catch (e) {
      console.error('DB error:', e.message);
      res.writeHead(500, headers);
      res.end(JSON.stringify({ error: 'Internal error' }));
    }
    return;
  }

  // ── Record swap ──
  if (req.method === 'POST' && url.pathname === '/api/swaps') {
    try {
      const b = req.verifiedBody;
      await dexDb.query(
        `INSERT INTO swap_history (tx_hash, chain_id, wallet, token_id, direction, amount_in, amount_out, oracle_price, block_number)
         VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9) ON CONFLICT (tx_hash) DO NOTHING`,
        [b.txHash, b.chainId, b.wallet, b.tokenId, b.direction, b.amountIn, b.amountOut, b.oraclePrice||0, b.blockNumber||0]
      );
      res.writeHead(200, headers);
      res.end(JSON.stringify({ ok: true }));
    } catch (e) {
      console.error('Swap insert error:', e.message);
      res.writeHead(500, headers);
      res.end(JSON.stringify({ error: 'Internal error' }));
    }
    return;
  }

  // ── Get swap history ──
  if (req.method === 'GET' && url.pathname === '/api/swaps') {
    try {
      const wallet = url.searchParams.get('wallet');
      const chainId = url.searchParams.get('chainId');
      const limit = Math.min(parseInt(url.searchParams.get('limit') || '50'), 200);
      let q = 'SELECT * FROM swap_history';
      const params = [];
      const where = [];
      if (wallet) { params.push(wallet.toLowerCase()); where.push(`LOWER(wallet) = $${params.length}`); }
      if (chainId) { params.push(parseInt(chainId)); where.push(`chain_id = $${params.length}`); }
      if (where.length) q += ' WHERE ' + where.join(' AND ');
      q += ' ORDER BY created_at DESC LIMIT $' + (params.length + 1);
      params.push(limit);
      const result = await dexDb.query(q, params);
      res.writeHead(200, headers);
      res.end(JSON.stringify({ swaps: result.rows }));
    } catch (e) {
      console.error('Swap query error:', e.message);
      res.writeHead(500, headers);
      res.end(JSON.stringify({ error: 'Internal error' }));
    }
    return;
  }

  // ── Record redeem ──
  if (req.method === 'POST' && url.pathname === '/api/redeems') {
    try {
      const b = req.verifiedBody;
      await dexDb.query(
        `INSERT INTO redeem_history (tx_hash, chain_id, wallet, dusdc_amount, usdc_amount, block_number)
         VALUES ($1,$2,$3,$4,$5,$6) ON CONFLICT (tx_hash) DO NOTHING`,
        [b.txHash, b.chainId, b.wallet, b.dusdcAmount, b.usdcAmount, b.blockNumber||0]
      );
      res.writeHead(200, headers);
      res.end(JSON.stringify({ ok: true }));
    } catch (e) {
      console.error('Redeem insert error:', e.message);
      res.writeHead(500, headers);
      res.end(JSON.stringify({ error: 'Internal error' }));
    }
    return;
  }

  // ── Record LP event ──
  if (req.method === 'POST' && url.pathname === '/api/lp-events') {
    try {
      const b = req.verifiedBody;
      await dexDb.query(
        `INSERT INTO lp_events (tx_hash, chain_id, wallet, event_type, token_id, amount, block_number)
         VALUES ($1,$2,$3,$4,$5,$6,$7) ON CONFLICT (tx_hash) DO NOTHING`,
        [b.txHash, b.chainId, b.wallet, b.eventType, b.tokenId||null, b.amount, b.blockNumber||0]
      );
      res.writeHead(200, headers);
      res.end(JSON.stringify({ ok: true }));
    } catch (e) {
      console.error('LP event insert error:', e.message);
      res.writeHead(500, headers);
      res.end(JSON.stringify({ error: 'Internal error' }));
    }
    return;
  }

  // ── Get activity (swaps + redeems + lp events merged) ──
  if (req.method === 'GET' && url.pathname === '/api/activity') {
    try {
      const wallet = url.searchParams.get('wallet');
      const networksParam = url.searchParams.get('networks');
      const networks = networksParam
        ? networksParam.split(',').map(n => parseInt(n, 10)).filter(n => Number.isFinite(n))
        : null;
      const limit = Math.min(parseInt(url.searchParams.get('limit') || '50'), 200);
      const conditions = [];
      const params = [];
      if (wallet) {
        params.push(wallet.toLowerCase());
        conditions.push(`LOWER(wallet) = $${params.length}`);
      }
      if (networks && networks.length) {
        params.push(networks);
        conditions.push(`chain_id = ANY($${params.length}::int[])`);
      }
      const whereClause = conditions.length ? `WHERE ${conditions.join(' AND ')}` : '';
      params.push(limit);
      const limitParam = `$${params.length}`;
      const result = await dexDb.query(`
        SELECT tx_hash, chain_id, wallet, 'swap' AS type, token_id, direction AS detail, amount_in, amount_out, created_at
        FROM swap_history ${whereClause}
        UNION ALL
        SELECT tx_hash, chain_id, wallet, 'redeem' AS type, 'dUSDC' AS token_id, 'redeem' AS detail, dusdc_amount AS amount_in, usdc_amount AS amount_out, created_at
        FROM redeem_history ${whereClause}
        UNION ALL
        SELECT tx_hash, chain_id, wallet, 'lp' AS type, token_id, event_type AS detail, amount AS amount_in, amount AS amount_out, created_at
        FROM lp_events ${whereClause}
        ORDER BY created_at DESC LIMIT ${limitParam}
      `, params);
      res.writeHead(200, headers);
      res.end(JSON.stringify({ activity: result.rows }));
    } catch (e) {
      console.error('Activity query error:', e.message);
      res.writeHead(500, headers);
      res.end(JSON.stringify({ error: 'Internal error' }));
    }
    return;
  }

  // ── Record oracle update ──
  if (req.method === 'POST' && url.pathname === '/api/oracle-updates') {
    try {
      const b = await readBody(req);
      await dexDb.query(
        `INSERT INTO oracle_updates (chain_id, token_id, token_address, price, block_number, tx_hash)
         VALUES ($1,$2,$3,$4,$5,$6)`,
        [b.chainId, b.tokenId, b.tokenAddress, b.price, b.blockNumber||0, b.txHash||null]
      );
      res.writeHead(200, headers);
      res.end(JSON.stringify({ ok: true }));
    } catch (e) {
      console.error('Oracle update insert error:', e.message);
      res.writeHead(500, headers);
      res.end(JSON.stringify({ error: 'Internal error' }));
    }
    return;
  }

  // ── Get oracle history ──
  if (req.method === 'GET' && url.pathname === '/api/oracle-updates') {
    try {
      const tokenId = url.searchParams.get('tokenId');
      const chainId = url.searchParams.get('chainId');
      const limit = Math.min(parseInt(url.searchParams.get('limit') || '30'), 200);
      const params = [];
      const where = [];
      if (tokenId) { params.push(tokenId); where.push(`token_id = $${params.length}`); }
      if (chainId) { params.push(parseInt(chainId)); where.push(`chain_id = $${params.length}`); }
      let q = 'SELECT * FROM oracle_updates';
      if (where.length) q += ' WHERE ' + where.join(' AND ');
      q += ' ORDER BY updated_at DESC LIMIT $' + (params.length + 1);
      params.push(limit);
      const result = await dexDb.query(q, params);
      res.writeHead(200, headers);
      res.end(JSON.stringify({ updates: result.rows }));
    } catch (e) {
      console.error('Oracle query error:', e.message);
      res.writeHead(500, headers);
      res.end(JSON.stringify({ error: 'Internal error' }));
    }
    return;
  }

  if (req.method === 'GET' && url.pathname === '/api/health') {
    res.writeHead(200, headers);
    res.end(JSON.stringify({ status: 'ok' }));
    return;
  }

  res.writeHead(404, headers);
  res.end(JSON.stringify({ error: 'Not found' }));
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`DobDex API listening on 127.0.0.1:${PORT}`);
});
