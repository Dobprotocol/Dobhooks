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
  port: parseInt(process.env.VAL_DB_PORT || '5433'),
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

// CORS headers for the frontend
const headers = {
  'Content-Type': 'application/json',
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type',
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
    req.on('data', c => { data += c; if (data.length > 1e6) reject(new Error('Too large')); });
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
      const b = await readBody(req);
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
      const b = await readBody(req);
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
      const b = await readBody(req);
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
