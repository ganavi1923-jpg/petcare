// Vercel Serverless Function entry point that re-uses the existing Express app
// The backend server exports the Express app (module.exports = app) after the conditional listen block.
// Vercel will invoke this function for any request under /api/*

const app = require('../backend/server');
module.exports = app;
