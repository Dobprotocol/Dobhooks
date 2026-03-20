/**
 * Generate TTS audio files for the DobDex demo page.
 * Uses OpenAI TTS API (tts-1-hd model, nova voice).
 *
 * Usage: OPENAI_API_KEY=sk-... node scripts/generate-demo-audio.js
 */

const fs = require('fs');
const path = require('path');
const https = require('https');

const OPENAI_API_KEY = process.env.OPENAI_API_KEY;
if (!OPENAI_API_KEY) {
  console.error('Set OPENAI_API_KEY env var');
  process.exit(1);
}

const SCENES = [
  { id: 'hero', text: 'Welcome to DobDex! The first zero-slippage DEX built for tokenized real-world assets. Powered by Uniswap V4 Custom Accounting Hooks. Live on three chains!' },
  { id: 'problem', text: 'Real-world assets represent a 16 trillion dollar market moving on-chain. But tokenized RWA holders face a critical problem. No exit liquidity. Traditional AMMs impose slippage that makes no sense for oracle-priced assets. And when an asset becomes distressed, there is no mechanism for orderly liquidation.' },
  { id: 'architecture', text: 'DobDex is the final piece of a full-stack RWA infrastructure. First, Dob Validator uses AI to validate real-world assets and creates oracle price feeds. Then, Token Studio tokenizes validated assets into ERC-20 participation tokens. Finally, DobDex provides zero-slippage swaps and LP-backed liquidations for those tokens.' },
  { id: 'trust-flywheel', text: 'Every asset on DobDex goes through a progressive trust process we call the Trust Flywheel. First, the asset owner backs the asset themselves, staking their reputation and providing documentation. Then, trusted validation partners like EY and McKinsey audit the fundamentals, verify revenue streams, and assess risk profiles. This is institutional-grade due diligence. Next, blockchain treasury firms and institutional LPs step in, backing the asset with real capital on our Liquidity Nodes. Only after the asset has been owner-backed, professionally validated, and institutionally supported, can retail investors trade it on DobDex. Every layer adds trust. Owner, validator, institution, retail. That is the flywheel.' },
  { id: 'swap', text: 'Here is how a zero-slippage swap works. A user initiates a swap on the Uniswap V4 Pool Manager. The beforeSwap hook intercepts and queries the Dob Validator Registry oracle. It returns a BeforeSwapDelta, the Pool Manager skips AMM math entirely. Settlement happens at the exact one-to-one oracle price. Zero slippage, guaranteed.' },
  { id: 'liquidation', text: 'When Dob Protocols AI validators detect asset distress, the permissionless Liquidity Node system activates. LPs deposit USDC and set per-asset conditions. They are filled in first-in first-out order during liquidations. LPs earn the penalty spread as profit. Anti flash-loan protections and time-locked withdrawals prevent manipulation.' },
  { id: 'chains', text: 'DobDex is deployed on Unichain Sepolia with the full Uniswap V4 hook integration. Base Sepolia with DobDirectSwap for multi-chain portability. And Reactive Network for cross-chain oracle monitoring and automated liquidation alerts.' },
  { id: 'market', text: 'The total addressable market is 1.33 trillion dollars in global infrastructure capital expenditure annually. We are starting with energy and data centers in Latin America, where over 250 billion dollars in infrastructure gaps exist every year. Our serviceable market is 18 billion, and our year one target is 27 million in routed capital expenditure. The global RWA market moving on-chain exceeds 16 trillion dollars. Our revenue model is a 1.5 percent protocol fee on liquidation fills.' },
  { id: 'contracts', text: 'The protocol consists of approximately 1,900 lines of Solidity across 8 smart contracts. DobPegHook for Uniswap V4 custom accounting. DobRwaVault for RWA deposits and dUSDC minting. DobValidatorRegistry as the on-chain oracle. DobLPRegistry for the permissionless LP system. And DobDirectSwap for chains without Uniswap V4.' },
  { id: 'tests', text: '77 tests. Zero failures. Across 7 test suites covering oracle operations, vault mechanics, hook swaps, liquidation flows, LP registration, token factory, and full integration tests.' },
  { id: 'roadmap', text: 'Looking ahead, we are building an AI agent marketplace for autonomous validators and LP strategy agents. Cross-chain dUSDC via LayerZero. And mainnet deployment on Unichain.' },
  { id: 'cta', text: 'DobDex. Zero slippage RWA liquidity infrastructure. Try the live demo, explore the code on GitHub, or read the protocol documentation.' },
];

const OUT_DIR = path.resolve(__dirname, '../app/demo-audio');

function generateAudio(scene) {
  return new Promise((resolve, reject) => {
    const outPath = path.join(OUT_DIR, `${scene.id}.mp3`);

    if (fs.existsSync(outPath)) {
      console.log(`[skip] ${scene.id}.mp3 already exists`);
      return resolve();
    }

    console.log(`[generating] ${scene.id}: "${scene.text.substring(0, 60)}..."`);

    const body = JSON.stringify({
      model: 'tts-1-hd',
      voice: 'nova',
      input: scene.text,
      speed: 1.1,
      response_format: 'mp3',
    });

    const req = https.request({
      hostname: 'api.openai.com',
      path: '/v1/audio/speech',
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${OPENAI_API_KEY}`,
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(body),
      },
    }, (res) => {
      if (res.statusCode !== 200) {
        let errBody = '';
        res.on('data', c => errBody += c);
        res.on('end', () => reject(new Error(`API error ${res.statusCode}: ${errBody}`)));
        return;
      }
      const chunks = [];
      res.on('data', chunk => chunks.push(chunk));
      res.on('end', () => {
        const buffer = Buffer.concat(chunks);
        fs.writeFileSync(outPath, buffer);
        console.log(`  -> saved ${scene.id}.mp3 (${(buffer.length / 1024).toFixed(1)} KB)`);
        resolve();
      });
    });

    req.on('error', reject);
    req.write(body);
    req.end();
  });
}

async function main() {
  fs.mkdirSync(OUT_DIR, { recursive: true });
  console.log(`Output: ${OUT_DIR}\n`);

  for (const scene of SCENES) {
    await generateAudio(scene);
  }

  console.log('\nDone! Audio files saved to app/demo-audio/');
}

main().catch(err => {
  console.error('Fatal:', err);
  process.exit(1);
});
