#!/bin/bash
# ===========================================
# DEPLOY DEPIX LIQUID WALLET + N8N
# Execute: bash deploy.sh
# ===========================================

set -e

echo ""
echo "╔══════════════════════════════════════╗"
echo "║   DepPix Liquid Wallet + n8n Deploy  ║"
echo "╚══════════════════════════════════════╝"
echo ""

# Criar diretório da aplicação
mkdir -p /opt/depix/api
cd /opt/depix

echo "📁 Criando index.js..."
cat > /opt/depix/api/index.js << 'INDEXEOF'
const express = require('express');
const axios = require('axios');

const app = express();
app.use(express.json());
app.use((req, res, next) => {
  res.header('Access-Control-Allow-Origin', '*');
  res.header('Access-Control-Allow-Headers', 'Content-Type, Authorization');
  res.header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  if (req.method === 'OPTIONS') return res.sendStatus(200);
  next();
});

const PORT   = process.env.PORT         || 3010;
const RPC_USER = process.env.RPC_USER   || 'rpcuser';
const RPC_PASS = process.env.RPC_PASS   || 'rpcpassword';
const RPC_HOST = process.env.RPC_HOST   || 'liquid-node';
const RPC_PORT = process.env.RPC_PORT   || '7041';

async function rpc(method, params = []) {
  const r = await axios.post(
    `http://${RPC_HOST}:${RPC_PORT}`,
    { jsonrpc: '1.0', id: method, method, params },
    { auth: { username: RPC_USER, password: RPC_PASS } }
  );
  if (r.data.error) throw new Error(r.data.error.message);
  return r.data.result;
}

// ── Health ──────────────────────────────────────────────────────────
app.get('/health', (req, res) => res.json({ status: 'ok', ts: new Date().toISOString() }));

// ── Info do nó ───────────────────────────────────────────────────────
app.get('/info', async (req, res) => {
  try {
    const [chain, net] = await Promise.all([rpc('getblockchaininfo'), rpc('getnetworkinfo')]);
    res.json({ chain, net });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── Saldo ────────────────────────────────────────────────────────────
app.get('/balance', async (req, res) => {
  try {
    const b = await rpc('getbalances');
    res.json(b);
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── Novo endereço ────────────────────────────────────────────────────
// POST /address/new  { "label": "pedido-001" }
app.post('/address/new', async (req, res) => {
  try {
    const label = req.body.label || '';
    const address = await rpc('getnewaddress', [label, 'bech32']);
    res.json({ address, label, network: 'liquid', created_at: new Date().toISOString() });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── Verificar pagamento de um endereço ───────────────────────────────
// GET /address/:address/check?expected=0.001&min_confirmations=2
app.get('/address/:address/check', async (req, res) => {
  try {
    const { address } = req.params;
    const expected      = req.query.expected      ? parseFloat(req.query.expected)      : null;
    const minConf       = req.query.min_confirmations ? parseInt(req.query.min_confirmations) : 2;

    const list = await rpc('listreceivedbyaddress', [0, true, true]);
    const found = list.find(a => a.address === address);

    if (!found) {
      return res.json({ address, paid: false, status: 'pending', received: 0, confirmations: 0, transactions: [] });
    }

    const received = found.amount || 0;
    const confirmations = found.confirmations || 0;

    let status = 'pending';
    if (received > 0) {
      if (confirmations < minConf) status = 'unconfirmed';
      else if (expected && received < expected) status = 'underpaid';
      else status = 'confirmed';
    }

    // Detalhes das txs
    const transactions = [];
    for (const txid of (found.txids || [])) {
      try {
        const tx = await rpc('gettransaction', [txid]);
        transactions.push({
          txid,
          amount: tx.amount,
          confirmations: tx.confirmations,
          time: tx.time ? new Date(tx.time * 1000).toISOString() : null,
          asset: tx.details?.[0]?.asset || null
        });
      } catch (_) { transactions.push({ txid }); }
    }

    res.json({
      address,
      paid: status === 'confirmed',
      status,
      received,
      expected,
      confirmations,
      label: found.label || '',
      transactions
    });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── Criar cobrança ───────────────────────────────────────────────────
// POST /charge/create  { "amount": 0.001, "label": "pedido-001", "description": "..." }
app.post('/charge/create', async (req, res) => {
  try {
    const { amount, label, description } = req.body;
    if (!amount) return res.status(400).json({ error: 'amount obrigatório' });

    const address = await rpc('getnewaddress', [label || 'depix', 'bech32']);
    res.json({
      id:          `charge_${Date.now()}`,
      address,
      amount:      parseFloat(amount),
      label:       label || 'depix',
      description: description || '',
      status:      'pending',
      network:     'liquid',
      created_at:  new Date().toISOString(),
      expires_at:  new Date(Date.now() + 30 * 60 * 1000).toISOString()
    });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── Status de cobrança ───────────────────────────────────────────────
// GET /charge/:address/status?expected_amount=0.001
app.get('/charge/:address/status', async (req, res) => {
  try {
    const { address } = req.params;
    const expected = req.query.expected_amount ? parseFloat(req.query.expected_amount) : null;

    const list = await rpc('listreceivedbyaddress', [0, true, true]);
    const found = list.find(a => a.address === address);

    const received = found?.amount || 0;
    const confirmations = found?.confirmations || 0;

    let status = 'pending';
    if (received > 0) {
      if (confirmations < 2) status = 'unconfirmed';
      else if (expected && received < expected) status = 'underpaid';
      else status = 'confirmed';
    }

    res.json({ address, status, received, expected, confirmations, paid: status === 'confirmed' });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── Listar transações recentes ────────────────────────────────────────
// GET /transactions?limit=20
app.get('/transactions', async (req, res) => {
  try {
    const limit = parseInt(req.query.limit) || 20;
    const txs = await rpc('listtransactions', ['*', limit, 0]);
    res.json(txs.reverse().map(tx => ({
      txid:          tx.txid,
      category:      tx.category,
      amount:        tx.amount,
      confirmations: tx.confirmations,
      status:        tx.confirmations >= 2 ? 'confirmed' : tx.confirmations > 0 ? 'unconfirmed' : 'mempool',
      address:       tx.address,
      label:         tx.label || '',
      time:          tx.time ? new Date(tx.time * 1000).toISOString() : null
    })));
  } catch (e) { res.status(500).json({ error: e.message }); }
});

app.listen(PORT, () => console.log(`DepPix API rodando na porta ${PORT} | RPC: ${RPC_HOST}:${RPC_PORT}`));
INDEXEOF

echo "📁 Criando hd-wallet.js..."
cat > /opt/depix/api/hd-wallet.js << 'HWEOF'
// Utilitários de suporte
module.exports = {
  satoshiToAmount: (s) => s / 1e8,
  amountToSatoshi: (a) => Math.round(a * 1e8),
  resolveStatus: (received, expected, confirmations, minConf = 2) => {
    if (received <= 0) return 'pending';
    if (confirmations < minConf) return 'unconfirmed';
    if (expected && received < expected) return 'underpaid';
    return 'confirmed';
  }
};
HWEOF

echo "📁 Criando package.json..."
cat > /opt/depix/api/package.json << 'PKGEOF'
{
  "name": "depix-liquid-api",
  "version": "1.0.0",
  "main": "index.js",
  "dependencies": {
    "express": "^4.18.2",
    "axios": "^1.6.0"
  }
}
PKGEOF

echo "📁 Criando docker-compose.yml..."
cat > /opt/depix/docker-compose.yml << 'COMPOSEEOF'
version: "3.8"

services:

  liquid-node:
    image: elementsproject/elementsd:22.0
    command: >
      elementsd
      -disablewallet=0
      -txindex=1
      -server=1
      -rest=1
      -rpcallowip=0.0.0.0/0
      -rpcbind=0.0.0.0
      -rpcuser=rpcuser
      -rpcpassword=rpcpassword
      -fallbackfee=0.0001
      -chain=liquidv1
    networks:
      - ktechnet
    volumes:
      - elements-data:/root/.elements
    ports:
      - "7041:7041"
      - "7042:7042"
    deploy:
      restart_policy:
        condition: any

  depix-api:
    image: node:20-alpine
    working_dir: /app
    command: sh -c "npm install && node index.js"
    environment:
      - PORT=3010
      - RPC_USER=rpcuser
      - RPC_PASS=rpcpassword
      - RPC_HOST=liquid-node
      - RPC_PORT=7041
    volumes:
      - /opt/depix/api:/app
    networks:
      - ktechnet
    ports:
      - "3010:3010"
    depends_on:
      - liquid-node
    deploy:
      restart_policy:
        condition: any

  n8n:
    image: n8nio/n8n:latest
    environment:
      - N8N_HOST=0.0.0.0
      - N8N_PORT=5678
      - N8N_PROTOCOL=http
      - WEBHOOK_URL=http://SEU_IP_AQUI:5678/
      - GENERIC_TIMEZONE=America/Sao_Paulo
    volumes:
      - n8n-data:/home/node/.n8n
    networks:
      - ktechnet
    ports:
      - "5678:5678"
    deploy:
      restart_policy:
        condition: any

volumes:
  elements-data:
  n8n-data:

networks:
  ktechnet:
    external: true
    name: ktechnet
COMPOSEEOF

echo ""
echo "✅ Arquivos criados em /opt/depix/"
echo ""
echo "══════════════════════════════════════════"
echo " PRÓXIMO PASSO — fazer o deploy no Swarm:"
echo "══════════════════════════════════════════"
echo ""
echo "  docker stack deploy -c /opt/depix/docker-compose.yml depix"
echo ""
echo " Aguarde ~30s e acesse:"
echo "  API  → http://$(hostname -I | awk '{print $1}'):3010/health"
echo "  n8n  → http://$(hostname -I | awk '{print $1}'):5678"
echo ""
ENDOFSCRIPT
