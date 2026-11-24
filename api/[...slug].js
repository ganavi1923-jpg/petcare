// Vercel catch‑all API route that forwards every request to the existing Express app
// This file allows the whole Express server (with all /api/* routes) to run as a Vercel serverless function.

const app = require('../backend/server');
module.exports = app;
