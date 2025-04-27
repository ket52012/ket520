#!/bin/bash

# 更新系统并安装基础环境
echo "更新系统并安装基础环境..."
yum -y update && yum -y install epel-release && yum -y install git curl wget npm sqlite

# 检查并安装 Node.js
echo "检查并安装 Node.js..."
if ! command -v node &> /dev/null; then
    echo "Node.js 未安装，正在安装..."
    curl -fsSL https://rpm.nodesource.com/setup_18.x | bash - && yum -y install nodejs
else
    echo "Node.js 已安装，版本：$(node -v)"
fi

# 检查并安装 pm2
echo "检查并安装 pm2..."
if ! command -v pm2 &> /dev/null; then
    echo "pm2 未安装，正在安装..."
    npm install -g pm2
    # 确保 pm2 命令可用，添加到 PATH
    PM2_PATH=$(npm config get prefix)/bin
    export PATH=$PATH:$PM2_PATH
    echo "export PATH=\$PATH:$PM2_PATH" >> ~/.bashrc
    source ~/.bashrc
else
    echo "pm2 已安装，版本：$(pm2 --version)"
fi

# 更新 pm2
echo "更新 pm2..."
pm2 update

# 创建项目目录
echo "创建项目目录..."
mkdir -p /root/trx-energy-rental /root/trx-energy-rental/public && cd /root/trx-energy-rental

# 创建 package.json
echo "创建 package.json..."
cat << 'EOF' > /root/trx-energy-rental/package.json
{
  "name": "trx-energy-rental",
  "version": "1.0.0",
  "main": "index.js",
  "dependencies": {
    "axios": "^1.6.8",
    "express": "^4.19.2",
    "qrcode": "^1.5.3",
    "speakeasy": "^2.0.0",
    "tronweb": "^5.3.2",
    "sqlite3": "^5.1.6"
  }
}
EOF

# 创建 index.js
echo "创建 index.js..."
cat << 'EOF' > /root/trx-energy-rental/index.js
const TronWeb = require('tronweb');
const axios = require('axios');
const express = require('express');
const speakeasy = require('speakeasy');
const QRCode = require('qrcode');
const sqlite3 = require('sqlite3').verbose();
const crypto = require('crypto');

const app = express();
app.use(express.json());
app.use(express.static('public'));

const tronWeb = new TronWeb({ fullHost: 'https://api.trongrid.io' });
const db = new sqlite3.Database('/root/trx-energy-rental/trx-energy.db');

const TRONGRID_API_KEY = '1cecb9b0-7c95-4cb3-8101-fe06186b43b8';

db.serialize(() => {
  db.run(`CREATE TABLE IF NOT EXISTS config (
    key TEXT PRIMARY KEY,
    value TEXT
  )`);
  db.run(`CREATE TABLE IF NOT EXISTS transactions (
    txID TEXT PRIMARY KEY,
    timestamp TEXT,
    sender TEXT,
    amount REAL,
    energy INTEGER
  )`);
  db.run(`CREATE TABLE IF NOT EXISTS processed_txids (
    txID TEXT PRIMARY KEY
  )`);
  db.run(`CREATE INDEX IF NOT EXISTS idx_timestamp ON transactions(timestamp)`);
  db.get("SELECT value FROM config WHERE key = 'receiveAddress'", (err, row) => {
    if (!row) {
      const defaultConfig = {
        receiveAddress: 'TH7HuaiBSdQZRoKKfaXFVqKxGgtDLohntv',
        energyPerTrx: 64000,
        apiKey: '你的API',
        apiSecret: '你的API Secret',
        username: '123',
        password: '123',
        twoFactorSecret: null,
        twoFactorEnabled: false,
        toastEnabled: true,
        soundEnabled: true,
        autoCleanEnabled: true,
        autoCleanInterval: 24,
        autoCleanDays: 1
      };
      for (const [key, value] of Object.entries(defaultConfig)) {
        db.run(`INSERT OR IGNORE INTO config (key, value) VALUES (?, ?)`, [key, JSON.stringify(value)]);
      }
    }
  });
});

const ITRX_API_URL = 'https://itrx.io/api/v1/frontend/order';
const ITRX_PRICE_URL = 'https://itrx.io/api/v1/frontend/order/price';

let clients = [];

async function getConfig(key) {
  return new Promise((resolve) => {
    db.get(`SELECT value FROM config WHERE key = ?`, [key], (err, row) => {
      resolve(row ? JSON.parse(row.value) : null);
    });
  });
}

async function setConfig(key, value) {
  return new Promise((resolve) => {
    db.run(`INSERT OR REPLACE INTO config (key, value) VALUES (?, ?)`, [key, JSON.stringify(value)], resolve);
  });
}

async function cleanCache(daysToKeep) {
  const cutoffDate = new Date();
  cutoffDate.setDate(cutoffDate.getDate() - daysToKeep);
  return new Promise((resolve) => {
    db.run(`DELETE FROM transactions WHERE timestamp < ?`, [cutoffDate.toISOString()], (err) => {
      if (err) console.error('清理 transactions 失败:', err);
      db.run(`DELETE FROM processed_txids WHERE txID NOT IN (SELECT txID FROM transactions)`, (err) => {
        if (err) console.error('清理 processed_txids 失败:', err);
        console.log(`已清理 ${daysToKeep} 天前的记录`);
        broadcastNotification(`已清理 ${daysToKeep} 天前的记录`);
        resolve();
      });
    });
  });
}

async function cleanAllRecords() {
  return new Promise((resolve) => {
    db.run(`DELETE FROM transactions`, (err) => {
      if (err) console.error('清除所有 transactions 失败:', err);
      db.run(`DELETE FROM processed_txids`, (err) => {
        if (err) console.error('清除所有 processed_txids 失败:', err);
        console.log('已清除所有交易记录');
        broadcastNotification('已清除所有交易记录');
        resolve();
      });
    });
  });
}

async function startAutoClean() {
  const autoCleanEnabled = await getConfig('autoCleanEnabled');
  const autoCleanInterval = await getConfig('autoCleanInterval') || 24;
  const autoCleanDays = await getConfig('autoCleanDays') || 1;
  if (autoCleanEnabled) {
    setInterval(() => cleanCache(autoCleanDays), autoCleanInterval * 60 * 60 * 1000);
    cleanCache(autoCleanDays);
  }
}

async function checkTransactions() {
  try {
    const receiveAddress = await getConfig('receiveAddress');
    const now = Date.now();
    const minTimestamp = now - 300000;
    const url = `https://api.trongrid.io/v1/accounts/${receiveAddress}/transactions?limit=20&min_timestamp=${minTimestamp}`;
    console.log(`请求 Trongrid API: ${url}, 时间范围: ${new Date(minTimestamp).toISOString()} - ${new Date(now).toISOString()}`);

    const response = await axios.get(url, {
      headers: { 'TRON-PRO-API-KEY': TRONGRID_API_KEY }
    });
    console.log('Trongrid API 响应:', JSON.stringify(response.data, null, 2));

    if (!response.data.success) {
      console.error('Trongrid API 返回失败:', JSON.stringify(response.data));
      return;
    }

    const transactions = response.data.data.filter(tx => 
      tx.raw_data && 
      tx.raw_data.contract && 
      tx.raw_data.contract[0].type === 'TransferContract' &&
      tronWeb.address.fromHex(tx.raw_data.contract[0].parameter.value.to_address) === receiveAddress &&
      tx.raw_data.timestamp >= minTimestamp
    );

    if (transactions.length === 0) {
      console.log('5 分钟内无新交易');
      return;
    }

    for (const tx of transactions) {
      const txID = tx.txID;
      const isProcessed = await new Promise((resolve) => {
        db.get(`SELECT txID FROM processed_txids WHERE txID = ?`, [txID], (err, row) => resolve(!!row));
      });
      if (isProcessed) {
        console.log(`交易 ${txID} 已处理，跳过`);
        continue;
      }

      const senderAddress = tronWeb.address.fromHex(tx.raw_data.contract[0].parameter.value.owner_address);
      const rawAmount = tx.raw_data.contract[0].parameter.value.amount;
      const amount = rawAmount / 1000000;

      if (amount < 1) {
        console.log(`交易 ${txID} 金额 ${amount} TRX 小于 1 TRX，忽略`);
        db.run(`INSERT INTO processed_txids (txID) VALUES (?)`, [txID]);
        continue;
      }

      const energyPerTrx = await getConfig('energyPerTrx');
      const energyToReturn = Math.floor(amount * energyPerTrx);

      if (energyToReturn <= 0 || energyToReturn > 1000000) {
        console.error(`交易 ${txID} 能量计算异常: amount=${amount}, energyPerTrx=${energyPerTrx}, energyToReturn=${energyToReturn}`);
        continue;
      }

      console.log(`交易 ${txID}: 原始金额=${rawAmount} SUN, 转换后=${amount} TRX, energyPerTrx=${energyPerTrx}, 返还能量=${energyToReturn}`);
      broadcastNotification(`收到 ${amount} TRX 从 ${senderAddress}`);
      await returnEnergy(senderAddress, energyToReturn, txID);

      db.run(`INSERT INTO transactions (txID, timestamp, sender, amount, energy) VALUES (?, ?, ?, ?, ?)`, 
        [txID, new Date().toISOString(), senderAddress, amount, energyToReturn], (err) => {
          if (err) console.error('插入 transactions 失败:', err);
        });
      db.run(`INSERT INTO processed_txids (txID) VALUES (?)`, [txID], (err) => {
        if (err) console.error('插入 processed_txids 失败:', err);
      });
      broadcastDataUpdate();
    }
  } catch (error) {
    console.error('检查交易出错:', error.message, error.stack);
  }
}

async function returnEnergy(recipientAddress, energyAmount, txID) {
  try {
    const apiKey = await getConfig('apiKey');
    const apiSecret = await getConfig('apiSecret');
    if (!apiKey || !apiSecret) {
      throw new Error('ITRX API 密钥未配置');
    }

    const timestamp = Math.floor(Date.now() / 1000).toString();
    const requestBody = { receive_address: recipientAddress, energy_amount: energyAmount, period: '1H' };
    const sortedJsonData = JSON.stringify(requestBody, Object.keys(requestBody).sort());
    const message = `${timestamp}&${sortedJsonData}`;
    const signature = crypto.createHmac('sha256', apiSecret).update(message).digest('hex');

    console.log(`发送 ITRX 请求: ${JSON.stringify(requestBody)}`);
    const response = await axios.post(ITRX_API_URL, requestBody, {
      headers: {
        'API-KEY': apiKey,
        'TIMESTAMP': timestamp,
        'SIGNATURE': signature,
        'Content-Type': 'application/json'
      }
    });
    console.log('能量返还响应:', JSON.stringify(response.data, null, 2));
    if (response.data.errno === 0) {
      console.log(`订单 ${txID} 成功，返还 ${energyAmount} 能量给 ${recipientAddress}`);
      broadcastNotification(`已返还 ${energyAmount} 能量给 ${recipientAddress}`);
      broadcastPriceUpdate();
    } else {
      throw new Error('ITRX API 返回错误: ' + JSON.stringify(response.data));
    }
  } catch (error) {
    console.error(`订单 ${txID} 失败:`, error.message);
    broadcastNotification(`能量返还失败: ${error.message}`);
  }
}

async function getEnergyPrice() {
  try {
    const apiKey = await getConfig(')/$(apiKey');
    const apiSecret = await getConfig('apiSecret');
    const response = await axios.get(ITRX_PRICE_URL, {
      params: { energy_amount: 64000, period: '1H' },
      headers: { 'API-KEY': apiKey, 'API-SECRET': apiSecret, 'Content-Type': 'application/json' }
    });
    if (typeof response.data.total_price === 'number') {
      const priceInTrx = response.data.total_price / 1000000;
      console.log(`转换后的价格: ${response.data.total_price} SUN = ${priceInTrx} TRX`);
      return { success: true, price: priceInTrx };
    } else {
      throw new Error('能量价格数据格式错误');
    }
  } catch (error) {
    console.error('获取能量价格出错:', error.message);
    return { success: false, message: error.message };
  }
}

app.get('/notifications', (req, res) => {
  res.setHeader('Content-Type', 'text/event-stream');
  res.setHeader('Cache-Control', 'no-cache');
  res.setHeader('Connection', 'keep-alive');
  res.flushHeaders();
  clients.push(res);
  req.on('close', () => clients = clients.filter(client => client !== res));
});

function broadcastNotification(message) {
  getConfig('toastEnabled').then(toastEnabled => {
    if (toastEnabled) {
      clients.forEach(client => client.write(`data: ${JSON.stringify({ type: 'notification', message })}\n\n`));
    }
  });
}

async function broadcastDataUpdate() {
  const today = new Date().toISOString().split('T')[0];
  const todayData = await new Promise((resolve) => {
    db.all(`SELECT * FROM transactions WHERE timestamp LIKE ?`, [`${today}%`], (err, rows) => {
      if (err) console.error('查询 transactions 失败:', err);
      resolve(rows || []);
    });
  });
  const todaySummary = {
    trx: todayData.reduce((sum, tx) => sum + tx.amount, 0) || 0,
    energy: todayData.reduce((sum, tx) => sum + tx.energy, 0) || 0,
    count: todayData.length
  };
  clients.forEach(client => client.write(`data: ${JSON.stringify({ type: 'data', today: todaySummary, history: todayData })}\n\n`));
}

async function broadcastPriceUpdate() {
  const priceData = await getEnergyPrice();
  clients.forEach(client => client.write(`data: ${JSON.stringify({ type: 'price', price: priceData })}\n\n`));
}

setInterval(checkTransactions, 5000);

app.post('/login', async (req, res) => {
  const { username, password } = req.body;
  const storedUsername = await getConfig('username');
  const storedPassword = await getConfig('password');
  if (username === storedUsername && password === storedPassword) {
    res.json({ success: true });
  } else {
    res.json({ success: false, message: '用户名或密码错误' });
  }
});

app.get('/data', async (req, res) => {
  const today = new Date().toISOString().split('T')[0];
  const todayData = await new Promise((resolve) => {
    db.all(`SELECT * FROM transactions WHERE timestamp LIKE ?`, [`${today}%`], (err, rows) => resolve(rows || []));
  });
  const todaySummary = {
    trx: todayData.reduce((sum, tx) => sum + tx.amount, 0) || 0,
    energy: todayData.reduce((sum, tx) => sum + tx.energy, 0) || 0,
    count: todayData.length
  };
  res.json({ today: todaySummary, history: todayData });
});

app.get('/config', async (req, res) => {
  const priceData = await getEnergyPrice();
  res.json({
    receiveAddress: await getConfig('receiveAddress'),
    energyPerTrx: await getConfig('energyPerTrx'),
    apiKey: await getConfig('apiKey'),
    apiSecret: await getConfig('apiSecret'),
    twoFactorEnabled: await getConfig('twoFactorEnabled'),
    toastEnabled: await getConfig('toastEnabled'),
    soundEnabled: await getConfig('soundEnabled'),
    autoCleanEnabled: await getConfig('autoCleanEnabled'),
    autoCleanInterval: await getConfig('autoCleanInterval'),
    autoCleanDays: await getConfig('autoCleanDays'),
    energyPrice: priceData
  });
});

app.post('/update-config', async (req, res) => {
  const { receiveAddress, energyPerTrx, apiKey, apiSecret, password, twoFactorCode, toastEnabled, soundEnabled } = req.body;
  const twoFactorEnabled = await getConfig('twoFactorEnabled');
  if (twoFactorEnabled && !await verifyTwoFactor(twoFactorCode)) {
    return res.json({ success: false, message: '谷歌验证码错误' });
  }
  if (receiveAddress) await setConfig('receiveAddress', receiveAddress);
  if (energyPerTrx) await setConfig('energyPerTrx', Number(energyPerTrx));
  if (apiKey) await setConfig('apiKey', apiKey);
  if (apiSecret) await setConfig('apiSecret', apiSecret);
  if (password) await setConfig('password', password);
  if (typeof toastEnabled !== 'undefined') await setConfig('toastEnabled', toastEnabled);
  if (typeof soundEnabled !== 'undefined') await setConfig('soundEnabled', soundEnabled);
  res.json({ success: true });
});

app.post('/clean-cache', async (req, res) => {
  const { daysToKeep } = req.body;
  await cleanCache(daysToKeep || 1);
  res.json({ success: true, message: `已清理 ${daysToKeep || 1} 天前的记录` });
});

app.post('/clean-all-records', async (req, res) => {
  await cleanAllRecords();
  res.json({ success: true, message: '已清除所有交易记录' });
});

app.post('/update-auto-clean', async (req, res) => {
  const { enabled, interval, days } = req.body;
  await setConfig('autoCleanEnabled', enabled);
  await setConfig('autoCleanInterval', interval || 24);
  await setConfig('autoCleanDays', days || 1);
  startAutoClean();
  res.json({ success: true, message: '自动清理设置已更新' });
});

app.get('/two-factor-setup', async (req, res) => {
  const secret = speakeasy.generateSecret({ name: 'TRX Energy Rental', length: 20 });
  await setConfig('twoFactorSecret', secret.base32);
  const qrCodeUrl = await QRCode.toDataURL(secret.otpauth_url);
  res.json({ qrCodeUrl, secret: secret.base32 });
});

app.post('/two-factor-enable', async (req, res) => {
  const { code } = req.body;
  if (await verifyTwoFactor(code)) {
    await setConfig('twoFactorEnabled', true);
    res.json({ success: true });
  } else {
    res.json({ success: false, message: '验证码错误' });
  }
});

app.post('/two-factor-disable', async (req, res) => {
  const { code } = req.body;
  const twoFactorEnabled = await getConfig('twoFactorEnabled');
  if (!twoFactorEnabled) {
    return res.json({ success: false, message: '谷歌验证未启用' });
  }
  if (await verifyTwoFactor(code)) {
    await setConfig('twoFactorEnabled', false);
    await setConfig('twoFactorSecret', null);
    res.json({ success: true, message: '谷歌验证已禁用' });
  } else {
    res.json({ success: false, message: '验证码错误' });
  }
});

async function verifyTwoFactor(code) {
  const secret = await getConfig('twoFactorSecret');
  return speakeasy.totp.verify({
    secret,
    encoding: 'base32',
    token: code
  });
}

startAutoClean();
app.listen(3000, '0.0.0.0', () => {
  console.log('服务运行在端口 3000');
});

db.serialize(() => {
  db.run(`DELETE FROM transactions`);
  db.run(`DELETE FROM processed_txids`);
  console.log('已清空历史记录');
});
EOF

# 创建 public/index.html
cat << 'EOF' > /root/trx-energy-rental/public/index.html
<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>登录 - TRX 能量租赁</title>
  <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css">
  <style>
    body {
      display: flex;
      justify-content: center;
      align-items: center;
      min-height: 100vh;
      background: url('https://images.unsplash.com/photo-1519681393784-d120267933ba?ixlib=rb-4.0.3&auto=format&fit=crop&w=1350&q=80') no-repeat center center fixed;
      background-size: cover;
      font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
      margin: 0;
    }
    .login-container {
      background: rgba(255, 255, 255, 0.9);
      padding: 2.5rem;
      border-radius: 15px;
      box-shadow: 0 8px 20px rgba(0, 0, 0, 0.1);
      width: 100%;
      max-width: 400px;
      color: #333;
    }
    .login-container h2 {
      font-size: 1.8rem;
      font-weight: 600;
      color: #333;
      text-align: center;
      margin-bottom: 1.5rem;
    }
    .form-control {
      border-radius: 8px;
      border: 1px solid #ddd;
      background: #fff;
      color: #333;
      padding: 0.75rem;
      font-size: 1rem;
      transition: border-color 0.3s, box-shadow 0.3s;
    }
    .form-control:focus {
      border-color: #007bff;
      box-shadow: 0 0 8px rgba(0, 123, 255, 0.2);
      outline: none;
    }
    .btn-primary {
      background-color: #007bff;
      border: none;
      border-radius: 8px;
      padding: 0.75rem;
      font-size: 1rem;
      font-weight: 500;
      width: 100%;
      transition: background-color 0.3s;
    }
    .btn-primary:hover {
      background-color: #0056b3;
    }
    .text-danger {
      font-size: 0.9rem;
      text-align: center;
      color: #ff6b6b;
    }
  </style>
</head>
<body>
  <div class="login-container">
    <h2>登录</h2>
    <form id="loginForm">
      <div class="mb-3">
        <label class="form-label">用户名</label>
        <input type="text" class="form-control" id="username" value="123">
      </div>
      <div class="mb-3">
        <label class="form-label">密码</label>
        <input type="password" class="form-control" id="password" value="123">
      </div>
      <button type="submit" class="btn btn-primary">登录</button>
    </form>
    <p id="error" class="text-danger mt-3"></p>
  </div>
  <script>
    document.getElementById('loginForm').addEventListener('submit', async (e) => {
      e.preventDefault();
      const username = document.getElementById('username').value;
      const password = document.getElementById('password').value;
      const res = await fetch('/login', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ username, password })
      });
      const data = await res.json();
      if (data.success) window.location.href = '/dashboard.html';
      else document.getElementById('error').textContent = data.message;
    });
  </script>
</body>
</html>
EOF

# 创建 public/dashboard.html
cat << 'EOF' > /root/trx-energy-rental/public/dashboard.html
<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>管理后台 - TRX 能量租赁</title>
  <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css">
  <link rel="stylesheet" href="style.css">
  <style>
    body {
      background: url('https://images.unsplash.com/photo-1519681393784-d120267933ba?ixlib=rb-4.0.3&auto=format&fit=crop&w=1350&q=80') no-repeat center center fixed;
      background-size: cover;
      font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
      color: #333;
    }
    .container {
      max-width: 1200px;
      padding: 2rem;
    }
    h2 {
      color: #fff;
      text-shadow: 1px 1px 2px rgba(0, 0, 0, 0.5);
    }
    .card {
      border: none;
      border-radius: 15px;
      box-shadow: 0 4px 15px rgba(0, 0, 0, 0.1);
      margin-bottom: 1.5rem;
      background: rgba(255, 255, 255, 0.7);
    }
    .card-header {
      background: #007bff;
      color: white;
      border-radius: 15px 15px 0 0;
      font-weight: 500;
      padding: 1rem 1.5rem;
    }
    .card-body {
      padding: 1.5rem;
    }
    .btn-custom {
      border-radius: 8px;
      padding: 0.5rem 1rem;
      font-weight: 500;
      transition: background-color 0.3s;
    }
    .btn-primary {
      background-color: #007bff;
      border: none;
    }
    .btn-primary:hover {
      background-color: #0056b3;
    }
    .btn-secondary {
      background-color: #6c757d;
      border: none;
    }
    .btn-secondary:hover {
      background-color: #5a6268;
    }
    .btn-success {
      background-color: #28a745;
      border: none;
    }
    .btn-success:hover {
      background-color: #218838;
    }
    .btn-info {
      background-color: #17a2b8;
      border: none;
    }
    .btn-info:hover {
      background-color: #138496;
    }
    .btn-warning {
      background-color: #ffc107;
      border: none;
      color: #333;
    }
    .btn-warning:hover {
      background-color: #e0a800;
    }
    .btn-danger {
      background-color: #dc3545;
      border: none;
    }
    .btn-danger:hover {
      background-color: #c82333;
    }
    .table {
      background: rgba(255, 255, 255, 0.7);
      border-radius: 10px;
      overflow: hidden;
      color: #333;
    }
    .table th, .table td {
      vertical-align: middle;
      border-color: #ddd;
    }
    .modal-content {
      border-radius: 15px;
      background: rgba(255, 255, 255, 0.9);
      color: #333;
    }
    .modal-header {
      background: #007bff;
      color: white;
      border-radius: 15px 15px 0 0;
    }
    .form-control {
      border-radius: 8px;
      border: 1px solid #ddd;
      background: #fff;
      color: #333;
      padding: 0.75rem;
      font-size: 1rem;
      transition: border-color 0.3s, box-shadow 0.3s;
    }
    .form-control:focus {
      border-color: #007bff;
      box-shadow: 0 0 8px rgba(0, 123, 255, 0.2);
      outline: none;
    }
    .form-label {
      color: #333;
    }
    .toast-container {
      position: fixed;
      top: 1rem;
      left: 1rem;
      z-index: 1050;
    }
    .toast {
      background: rgba(255, 255, 255, 0.9);
      color: #333;
      border: 1px solid #ddd;
      border-radius: 8px;
    }
    .toast-header {
      background: #007bff;
      color: white;
      border-bottom: 1px solid #ddd;
    }
    .form-check-input:checked {
      background-color: #007bff;
      border-color: #007bff;
    }
  </style>
</head>
<body>
  <div class="container">
    <h2 class="mb-4">TRX 能量租赁 - 管理后台</h2>

    <div class="toast-container" id="toastContainer"></div>

    <div class="row mb-4">
      <div class="col-md-6">
        <div class="card">
          <div class="card-header">收款地址</div>
          <div class="card-body">
            <p>
              <span id="receiveAddressDisplay"></span>
              <button class="btn btn-info btn-custom btn-sm ms-2" onclick="copyAddress()">复制</button>
            </p>
          </div>
        </div>
      </div>
      <div class="col-md-6">
        <div class="card">
          <div class="card-header">能量价格</div>
          <div class="card-body">
            <p>64K 能量: <span id="energyPrice">加载中...</span>（1小时）</p>
            <a href="https://itrx.io" target="_blank" class="btn btn-success btn-custom">前往官网充值</a>
          </div>
        </div>
      </div>
    </div>

    <div class="row mb-4">
      <div class="col-md-12">
        <div class="card">
          <div class="card-header">今日数据</div>
          <div class="card-body">
            <div class="row">
              <div class="col-md-4">
                <p><strong>TRX:</strong> <span id="todayTrx"></span></p>
              </div>
              <div class="col-md-4">
                <p><strong>能量:</strong> <span id="todayEnergy"></span></p>
              </div>
              <div class="col-md-4">
                <p><strong>交易次数:</strong> <span id="todayCount"></span></p>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>

    <div class="row mb-4">
      <div class="col-md-12">
        <div class="card">
          <div class="card-header">操作</div>
          <div class="card-body">
            <button class="btn btn-primary btn-custom me-2" data-bs-toggle="modal" data-bs-target="#energyModal">设置能量比例</button>
            <button class="btn btn-primary btn-custom me-2" data-bs-toggle="modal" data-bs-target="#passwordModal">修改密码</button>
            <button class="btn btn-primary btn-custom me-2" data-bs-toggle="modal" data-bs-target="#securityModal">安全设置</button>
            <button class="btn btn-primary btn-custom me-2" data-bs-toggle="modal" data-bs-target="#notificationModal">通知设置</button>
            <button class="btn btn-warning btn-custom me-2" data-bs-toggle="modal" data-bs-target="#cleanCacheModal">交易记录管理</button>
            <button class="btn btn-secondary btn-custom" id="twoFactorBtn" data-bs-toggle="modal" data-bs-target="#twoFactorModal">设置谷歌验证</button>
          </div>
        </div>
      </div>
    </div>

    <div class="row">
      <div class="col-md-12">
        <div class="card">
          <div class="card-header">历史数据</div>
          <div class="card-body">
            <table class="table table-striped">
              <thead>
                <tr>
                  <th>时间</th>
                  <th>发送者</th>
                  <th>TRX</th>
                  <th>能量</th>
                </tr>
              </thead>
              <tbody id="historyTable"></tbody>
            </table>
          </div>
        </div>
      </div>
    </div>
  </div>

  <div class="modal fade" id="energyModal" tabindex="-1" aria-labelledby="energyModalLabel" aria-hidden="true">
    <div class="modal-dialog">
      <div class="modal-content">
        <div class="modal-header">
          <h5 class="modal-title" id="energyModalLabel">设置能量比例</h5>
          <button type="button" class="btn-close btn-close-white" data-bs-dismiss="modal" aria-label="Close"></button>
        </div>
        <div class="modal-body">
          <form id="energyForm">
            <div class="mb-3">
              <label class="form-label">每 TRX 能量</label>
              <input type="number" class="form-control" id="energyPerTrxModal">
            </div>
            <div class="mb-3" id="energyTwoFactorDiv" style="display: none;">
              <label class="form-label">谷歌验证码</label>
              <input type="text" class="form-control" id="energyTwoFactorCode">
            </div>
            <button type="submit" class="btn btn-primary btn-custom">保存</button>
          </form>
        </div>
      </div>
    </div>
  </div>

  <div class="modal fade" id="passwordModal" tabindex="-1" aria-labelledby="passwordModalLabel" aria-hidden="true">
    <div class="modal-dialog">
      <div class="modal-content">
        <div class="modal-header">
          <h5 class="modal-title" id="passwordModalLabel">修改密码</h5>
          <button type="button" class="btn-close btn-close-white" data-bs-dismiss="modal" aria-label="Close"></button>
        </div>
        <div class="modal-body">
          <form id="passwordForm">
            <div class="mb-3">
              <label class="form-label">新密码</label>
              <input type="password" class="form-control" id="newPassword">
            </div>
            <div class="mb-3" id="passwordTwoFactorDiv" style="display: none;">
              <label class="form-label">谷歌验证码</label>
              <input type="text" class="form-control" id="passwordTwoFactorCode">
            </div>
            <button type="submit" class="btn btn-primary btn-custom">保存</button>
          </form>
        </div>
      </div>
    </div>
  </div>

  <div class="modal fade" id="securityModal" tabindex="-1" aria-labelledby="securityModalLabel" aria-hidden="true">
    <div class="modal-dialog">
      <div class="modal-content">
        <div class="modal-header">
          <h5 class="modal-title" id="securityModalLabel">安全设置</h5>
          <button type="button" class="btn-close btn-close-white" data-bs-dismiss="modal" aria-label="Close"></button>
        </div>
        <div class="modal-body">
          <form id="securityForm">
            <div class="mb-3">
              <label class="form-label">收款地址</label>
              <input type="text" class="form-control" id="receiveAddressModal">
            </div>
            <div class="mb-3">
              <label class="form-label">API Key</label>
              <input type="text" class="form-control" id="apiKeyModal">
            </div>
            <div class="mb-3">
              <label class="form-label">API Secret</label>
              <input type="text" class="form-control" id="apiSecretModal">
            </div>
            <div class="mb-3" id="securityTwoFactorDiv" style="display: none;">
              <label class="form-label">谷歌验证码</label>
              <input type="text" class="form-control" id="securityTwoFactorCode">
            </div>
            <button type="submit" class="btn btn-primary btn-custom">保存</button>
          </form>
        </div>
      </div>
    </div>
  </div>

  <div class="modal fade" id="notificationModal" tabindex="-1" aria-labelledby="notificationModalLabel" aria-hidden="true">
    <div class="modal-dialog">
      <div class="modal-content">
        <div class="modal-header">
          <h5 class="modal-title" id="notificationModalLabel">通知设置</h5>
          <button type="button" class="btn-close btn-close-white" data-bs-dismiss="modal" aria-label="Close"></button>
        </div>
        <div class="modal-body">
          <form id="notificationForm">
            <div class="mb-3 form-check">
              <input type="checkbox" class="form-check-input" id="toastEnabled">
              <label class="form-check-label" for="toastEnabled">启用浮窗通知</label>
            </div>
            <div class="mb-3 form-check">
              <input type="checkbox" class="form-check-input" id="soundEnabled">
              <label class="form-check-label" for="soundEnabled">启用声音通知</label>
            </div>
            <button type="submit" class="btn btn-primary btn-custom">保存</button>
          </form>
        </div>
      </div>
    </div>
  </div>

  <div class="modal fade" id="cleanCacheModal" tabindex="-1" aria-labelledby="cleanCacheModalLabel" aria-hidden="true">
    <div class="modal-dialog">
      <div class="modal-content">
        <div class="modal-header">
          <h5 class="modal-title" id="cleanCacheModalLabel">交易记录管理</h5>
          <button type="button" class="btn-close btn-close-white" data-bs-dismiss="modal" aria-label="Close"></button>
        </div>
        <div class="modal-body">
          <form id="cleanCacheForm">
            <div class="mb-3">
              <label class="form-label">保留最近几天的数据</label>
              <input type="number" class="form-control" id="daysToKeep" value="1" min="1">
            </div>
            <button type="submit" class="btn btn-warning btn-custom">清理缓存</button>
          </form>
          <button class="btn btn-danger btn-custom mt-3 w-100" onclick="cleanAllRecords()">清除所有记录</button>
          <hr>
          <h6>自动清理设置</h6>
          <form id="autoCleanForm">
            <div class="mb-3 form-check">
              <input type="checkbox" class="form-check-input" id="autoCleanEnabled">
              <label class="form-check-label" for="autoCleanEnabled">启用自动清理</label>
            </div>
            <div class="mb-3">
              <label class="form-label">清理间隔（小时）</label>
              <input type="number" class="form-control" id="autoCleanInterval" value="24" min="1">
            </div>
            <div class="mb-3">
              <label class="form-label">保留最近几天的数据</label>
              <input type="number" class="form-control" id="autoCleanDays" value="1" min="1">
            </div>
            <button type="submit" class="btn btn-primary btn-custom">保存</button>
          </form>
          <div id="cleanCacheMessage" class="mt-3" style="display: none;"></div>
        </div>
      </div>
    </div>
  </div>

  <div class="modal fade" id="twoFactorModal" tabindex="-1" aria-labelledby="twoFactorModalLabel" aria-hidden="true">
    <div class="modal-dialog">
      <div class="modal-content">
        <div class="modal-header">
          <h5 class="modal-title" id="twoFactorModalLabel">谷歌验证设置</h5>
          <button type="button" class="btn-close btn-close-white" data-bs-dismiss="modal" aria-label="Close"></button>
        </div>
        <div class="modal-body">
          <div id="qrCodeContainer"></div>
          <p id="qrCodeDebug" style="display: none;"></p>
          <form id="twoFactorForm">
            <div class="mb-3">
              <label class="form-label">验证码</label>
              <input type="text" class="form-control" id="twoFactorCode">
            </div>
            <button type="submit" class="btn btn-primary btn-custom">启用</button>
          </form>
          <form id="twoFactorDisableForm" class="mt-3" style="display: none;">
            <div class="mb-3">
              <label class="form-label">验证码</label>
              <input type="text" class="form-control" id="twoFactorDisableCode">
            </div>
            <button type="submit" class="btn btn-danger btn-custom">禁用</button>
          </form>
          <p id="twoFactorError" class="text-danger mt-3"></p>
        </div>
      </div>
    </div>
  </div>

  <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/js/bootstrap.bundle.min.js"></script>
  <script>
    let twoFactorEnabled = false;

    async function loadConfig() {
      try {
        const res = await fetch('/config');
        const config = await res.json();
        document.getElementById('receiveAddressDisplay').textContent = config.receiveAddress;
        document.getElementById('energyPerTrxModal').value = config.energyPerTrx;
        document.getElementById('receiveAddressModal').value = config.receiveAddress;
        document.getElementById('apiKeyModal').value = config.apiKey;
        document.getElementById('apiSecretModal').value = config.apiSecret;
        document.getElementById('toastEnabled').checked = config.toastEnabled;
        document.getElementById('soundEnabled').checked = config.soundEnabled;
        document.getElementById('autoCleanEnabled').checked = config.autoCleanEnabled;
        document.getElementById('autoCleanInterval').value = config.autoCleanInterval;
        document.getElementById('autoCleanDays').value = config.autoCleanDays;
        twoFactorEnabled = config.twoFactorEnabled;
        document.getElementById('energyTwoFactorDiv').style.display = twoFactorEnabled ? 'block' : 'none';
        document.getElementById('passwordTwoFactorDiv').style.display = twoFactorEnabled ? 'block' : 'none';
        document.getElementById('securityTwoFactorDiv').style.display = twoFactorEnabled ? 'block' : 'none';
        document.getElementById('twoFactorBtn').textContent = twoFactorEnabled ? '修改谷歌验证' : '设置谷歌验证';
        document.getElementById('twoFactorDisableForm').style.display = twoFactorEnabled ? 'block' : 'none';
        updatePriceDisplay(config.energyPrice);
      } catch (error) {
        console.error('加载配置失败:', error);
        document.getElementById('energyPrice').textContent = '错误: 网络请求失败';
      }
    }

    function updatePriceDisplay(priceData) {
      if (priceData && priceData.success) {
        document.getElementById('energyPrice').textContent = `${priceData.price} TRX`;
      } else {
        document.getElementById('energyPrice').textContent = `错误: ${priceData ? priceData.message : '未知错误'}`;
      }
    }

    async function loadData() {
      try {
        const res = await fetch('/data');
        const data = await res.json();
        document.getElementById('todayTrx').textContent = data.today.trx;
        document.getElementById('todayEnergy').textContent = data.today.energy;
        document.getElementById('todayCount').textContent = data.today.count;
        const historyTable = document.getElementById('historyTable');
        historyTable.innerHTML = '';
        data.history.forEach(tx => {
          const row = document.createElement('tr');
          row.innerHTML = `
            <td>${new Date(tx.timestamp).toLocaleString()}</td>
            <td>${tx.sender}</td>
            <td>${tx.amount}</td>
            <td>${tx.energy}</td>
          `;
          historyTable.appendChild(row);
        });
      } catch (error) {
        console.error('加载数据失败:', error);
      }
    }

    function copyAddress() {
      navigator.clipboard.writeText(document.getElementById('receiveAddressDisplay').textContent);
      alert('地址已复制');
    }

    const eventSource = new EventSource('/notifications');
    eventSource.onmessage = (event) => {
      const data = JSON.parse(event.data);
      if (data.type === 'notification') {
        showToast(data.message);
      } else if (data.type === 'data') {
        document.getElementById('todayTrx').textContent = data.today.trx;
        document.getElementById('todayEnergy').textContent = data.today.energy;
        document.getElementById('todayCount').textContent = data.today.count;
        const historyTable = document.getElementById('historyTable');
        historyTable.innerHTML = '';
        data.history.forEach(tx => {
          const row = document.createElement('tr');
          row.innerHTML = `
            <td>${new Date(tx.timestamp).toLocaleString()}</td>
            <td>${tx.sender}</td>
            <td>${tx.amount}</td>
            <td>${tx.energy}</td>
          `;
          historyTable.appendChild(row);
        });
      } else if (data.type === 'price') {
        updatePriceDisplay(data.price);
      }
    };

    function showToast(message) {
      const toastContainer = document.getElementById('toastContainer');
      const toast = document.createElement('div');
      toast.className = 'toast';
      toast.innerHTML = `
        <div class="toast-header">
          <strong class="me-auto">通知</strong>
          <button type="button" class="btn-close" data-bs-dismiss="toast" aria-label="Close"></button>
        </div>
        <div class="toast-body">${message}</div>
      `;
      toastContainer.appendChild(toast);
      const bsToast = new bootstrap.Toast(toast);
      bsToast.show();
      toast.addEventListener('hidden.bs.toast', () => toast.remove());
    }

    document.getElementById('energyForm').addEventListener('submit', async (e) => {
      e.preventDefault();
      const energyPerTrx = document.getElementById('energyPerTrxModal').value;
      const twoFactorCode = document.getElementById('energyTwoFactorCode').value;
      const res = await fetch('/update-config', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ energyPerTrx, twoFactorCode })
      });
      const data = await res.json();
      if (data.success) {
        bootstrap.Modal.getInstance(document.getElementById('energyModal')).hide();
        loadConfig();
      } else {
        alert(data.message);
      }
    });

    document.getElementById('passwordForm').addEventListener('submit', async (e) => {
      e.preventDefault();
      const password = document.getElementById('newPassword').value;
      const twoFactorCode = document.getElementById('passwordTwoFactorCode').value;
      const res = await fetch('/update-config', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ password, twoFactorCode })
      });
      const data = await res.json();
      if (data.success) {
        bootstrap.Modal.getInstance(document.getElementById('passwordModal')).hide();
        alert('密码已修改');
      } else {
        alert(data.message);
      }
    });

    document.getElementById('securityForm').addEventListener('submit', async (e) => {
      e.preventDefault();
      const receiveAddress = document.getElementById('receiveAddressModal').value;
      const apiKey = document.getElementById('apiKeyModal').value;
      const apiSecret = document.getElementById('apiSecretModal').value;
      const twoFactorCode = document.getElementById('securityTwoFactorCode').value;
      const res = await fetch('/update-config', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ receiveAddress, apiKey, apiSecret, twoFactorCode })
      });
      const data = await res.json();
      if (data.success) {
        bootstrap.Modal.getInstance(document.getElementById('securityModal')).hide();
        loadConfig();
      } else {
        alert(data.message);
      }
    });

    document.getElementById('notificationForm').addEventListener('submit', async (e) => {
      e.preventDefault();
      const toastEnabled = document.getElementById('toastEnabled').checked;
      const soundEnabled = document.getElementById('soundEnabled').checked;
      const res = await fetch('/update-config', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ toastEnabled, soundEnabled })
      });
      const data = await res.json();
      if (data.success) {
        bootstrap.Modal.getInstance(document.getElementById('notificationModal')).hide();
      }
    });

    document.getElementById('cleanCacheForm').addEventListener('submit', async (e) => {
      e.preventDefault();
      const daysToKeep = document.getElementById('daysToKeep').value;
      const res = await fetch('/clean-cache', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ daysToKeep: parseInt(daysToKeep) })
      });
      const data = await res.json();
      if (data.success) {
        document.getElementById('cleanCacheMessage').textContent = data.message;
        document.getElementById('cleanCacheMessage').className = 'text-success';
        document.getElementById('cleanCacheMessage').style.display = 'block';
        setTimeout(() => document.getElementById('cleanCacheMessage').style.display = 'none', 3000);
        loadData();
      } else {
        document.getElementById('cleanCacheMessage').textContent = data.message;
        document.getElementById('cleanCacheMessage').className = 'text-danger';
        document.getElementById('cleanCacheMessage').style.display = 'block';
      }
    });

    async function cleanAllRecords() {
      if (!confirm('确定要清除所有交易记录吗？')) return;
      const res = await fetch('/clean-all-records', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' }
      });
      const data = await res.json();
      if (data.success) {
        document.getElementById('cleanCacheMessage').textContent = data.message;
        document.getElementById('cleanCacheMessage').className = 'text-success';
        document.getElementById('cleanCacheMessage').style.display = 'block';
        setTimeout(() => document.getElementById('cleanCacheMessage').style.display = 'none', 3000);
        loadData();
      } else {
        document.getElementById('cleanCacheMessage').textContent = data.message;
        document.getElementById('cleanCacheMessage').className = 'text-danger';
        document.getElementById('cleanCacheMessage').style.display = 'block';
      }
    }

    document.getElementById('autoCleanForm').addEventListener('submit', async (e) => {
      e.preventDefault();
      const enabled = document.getElementById('autoCleanEnabled').checked;
      const interval = document.getElementById('autoCleanInterval').value;
      const days = document.getElementById('autoCleanDays').value;
      const res = await fetch('/update-auto-clean', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ enabled, interval: parseInt(interval), days: parseInt(days) })
      });
      const data = await res.json();
      if (data.success) {
        document.getElementById('cleanCacheMessage').textContent = data.message;
        document.getElementById('cleanCacheMessage').className = 'text-success';
        document.getElementById('cleanCacheMessage').style.display = 'block';
        setTimeout(() => document.getElementById('cleanCacheMessage').style.display = 'none', 3000);
      } else {
        document.getElementById('cleanCacheMessage').textContent = data.message;
        document.getElementById('cleanCacheMessage').className = 'text-danger';
        document.getElementById('cleanCacheMessage').style.display = 'block';
      }
    });

    document.getElementById('twoFactorBtn').addEventListener('click', async () => {
      const modal = new bootstrap.Modal(document.getElementById('twoFactorModal'));
      modal.show();
      if (!twoFactorEnabled) {
        const res = await fetch('/two-factor-setup');
        const data = await res.json();
        document.getElementById('qrCodeContainer').innerHTML = `<img src="${data.qrCodeUrl}" alt="QR Code" style="max-width: 200px;">`;
        document.getElementById('qrCodeDebug').textContent = `密钥: ${data.secret}`;
      }
    });

    document.getElementById('twoFactorForm').addEventListener('submit', async (e) => {
      e.preventDefault();
      const code = document.getElementById('twoFactorCode').value;
      const res = await fetch('/two-factor-enable', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ code })
      });
      const data = await res.json();
      if (data.success) {
        twoFactorEnabled = true;
        document.getElementById('energyTwoFactorDiv').style.display = 'block';
        document.getElementById('passwordTwoFactorDiv').style.display = 'block';
        document.getElementById('securityTwoFactorDiv').style.display = 'block';
        document.getElementById('twoFactorBtn').textContent = '修改谷歌验证';
        document.getElementById('twoFactorDisableForm').style.display = 'block';
        bootstrap.Modal.getInstance(document.getElementById('twoFactorModal')).hide();
        alert('谷歌验证已启用');
      } else {
        document.getElementById('twoFactorError').textContent = data.message;
      }
    });

    document.getElementById('twoFactorDisableForm').addEventListener('submit', async (e) => {
      e.preventDefault();
      const code = document.getElementById('twoFactorDisableCode').value;
      const res = await fetch('/two-factor-disable', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ code })
      });
      const data = await res.json();
      if (data.success) {
        twoFactorEnabled = false;
        document.getElementById('energyTwoFactorDiv').style.display = 'none';
        document.getElementById('passwordTwoFactorDiv').style.display = 'none';
        document.getElementById('securityTwoFactorDiv').style.display = 'none';
        document.getElementById('twoFactorBtn').textContent = '设置谷歌验证';
        document.getElementById('twoFactorDisableForm').style.display = 'none';
        document.getElementById('qrCodeContainer').innerHTML = '';
        bootstrap.Modal.getInstance(document.getElementById('twoFactorModal')).hide();
        alert(data.message);
      } else {
        document.getElementById('twoFactorError').textContent = data.message;
      }
    });

    loadConfig();
    loadData();
  </script>
</body>
</html>
EOF

# 创建 public/style.css
cat << 'EOF' > /root/trx-energy-rental/public/style.css
body {
  background-color: #2c2f33;
}
.container {
  max-width: 1200px;
}
.table {
  background-color: #3a3f44;
}
EOF

# 删除旧服务并清理
echo "清理旧服务..."
pm2 stop trx-energy 2>/dev/null && \
pm2 delete trx-energy 2>/dev/null && \
pm2 save

# 安装依赖并启动服务
echo "安装依赖并启动服务..."
cd /root/trx-energy-rental && \
npm install && \
pm2 start index.js --name trx-energy && \
pm2 save

# 检查并安装 firewalld，开放 3000 端口
echo "检查并安装 firewalld..."
if ! command -v firewall-cmd &> /dev/null; then
    echo "firewalld 未安装，正在安装..."
    yum install -y firewalld
    if [ $? -ne 0 ]; then
        echo "警告：firewalld 安装失败，尝试使用 iptables 开放端口..."
        # 检查是否安装 iptables
        if ! command -v iptables &> /dev/null; then
            echo "iptables 未安装，正在安装..."
            yum install -y iptables-services
        fi
        # 使用 iptables 开放 3000 端口
        iptables -A INPUT -p tcp --dport 3000 -j ACCEPT
        # 保存 iptables 规则
        service iptables save 2>/dev/null || echo "警告：iptables 规则保存失败，请手动保存"
    else
        # 启动并启用 firewalld
        systemctl start firewalld
        systemctl enable firewalld
        # 开放 3000 端口
        echo "开放 3000 端口..."
        firewall-cmd --add-port=3000/tcp --permanent
        firewall-cmd --reload
    fi
else
    # firewalld 已安装，直接开放端口
    echo "开放 3000 端口..."
    firewall-cmd --add-port=3000/tcp --permanent
    firewall-cmd --reload
fi

# 完成提示 
echo "TRX 能量租赁项目部署完成！请访问 http://<您的服务器IP>:3000"
