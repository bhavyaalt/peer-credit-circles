-- PCC Supabase Schema
-- Run this in your Supabase SQL editor

-- ============================================
-- POOLS
-- ============================================
CREATE TABLE pools (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  address TEXT UNIQUE NOT NULL,
  chain_id INTEGER NOT NULL DEFAULT 8453, -- Base mainnet
  name TEXT NOT NULL,
  deposit_token TEXT NOT NULL,
  min_deposit NUMERIC NOT NULL,
  voting_period INTEGER NOT NULL, -- seconds
  quorum_bps INTEGER NOT NULL,
  approval_bps INTEGER NOT NULL,
  guardian_threshold_bps INTEGER NOT NULL,
  admin_address TEXT NOT NULL,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  created_tx TEXT,
  total_deposited NUMERIC DEFAULT 0,
  member_count INTEGER DEFAULT 0,
  is_active BOOLEAN DEFAULT true
);

CREATE INDEX idx_pools_admin ON pools(admin_address);
CREATE INDEX idx_pools_chain ON pools(chain_id);

-- ============================================
-- MEMBERS
-- ============================================
CREATE TABLE members (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  pool_id UUID REFERENCES pools(id) ON DELETE CASCADE,
  address TEXT NOT NULL,
  is_guardian BOOLEAN DEFAULT false,
  is_active BOOLEAN DEFAULT true,
  shares NUMERIC DEFAULT 0,
  total_deposited NUMERIC DEFAULT 0,
  total_withdrawn NUMERIC DEFAULT 0,
  joined_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(pool_id, address)
);

CREATE INDEX idx_members_pool ON members(pool_id);
CREATE INDEX idx_members_address ON members(address);

-- ============================================
-- FUNDING REQUESTS
-- ============================================
CREATE TABLE requests (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  pool_id UUID REFERENCES pools(id) ON DELETE CASCADE,
  onchain_id INTEGER NOT NULL,
  requester_address TEXT NOT NULL,
  title TEXT NOT NULL,
  description TEXT,
  description_uri TEXT, -- IPFS link
  amount NUMERIC NOT NULL,
  request_type TEXT NOT NULL CHECK (request_type IN ('GRANT', 'LOAN', 'INVESTMENT')),
  reward_bps INTEGER DEFAULT 0,
  duration INTEGER, -- seconds
  collateral_token TEXT,
  collateral_amount NUMERIC DEFAULT 0,
  status TEXT NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING', 'VOTING', 'APPROVED', 'REJECTED', 'FUNDED', 'COMPLETED', 'DEFAULTED', 'CANCELLED')),
  yes_votes NUMERIC DEFAULT 0,
  no_votes NUMERIC DEFAULT 0,
  voting_ends_at TIMESTAMPTZ,
  guardian_approvals INTEGER DEFAULT 0,
  funded_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(pool_id, onchain_id)
);

CREATE INDEX idx_requests_pool ON requests(pool_id);
CREATE INDEX idx_requests_requester ON requests(requester_address);
CREATE INDEX idx_requests_status ON requests(status);

-- ============================================
-- VOTES
-- ============================================
CREATE TABLE votes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  request_id UUID REFERENCES requests(id) ON DELETE CASCADE,
  voter_address TEXT NOT NULL,
  support BOOLEAN NOT NULL,
  weight NUMERIC NOT NULL,
  voted_at TIMESTAMPTZ DEFAULT NOW(),
  tx_hash TEXT,
  UNIQUE(request_id, voter_address)
);

CREATE INDEX idx_votes_request ON votes(request_id);
CREATE INDEX idx_votes_voter ON votes(voter_address);

-- ============================================
-- TRANSACTIONS (deposits/withdrawals)
-- ============================================
CREATE TABLE transactions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  pool_id UUID REFERENCES pools(id) ON DELETE CASCADE,
  address TEXT NOT NULL,
  tx_type TEXT NOT NULL CHECK (tx_type IN ('DEPOSIT', 'WITHDRAW', 'FUND', 'REPAY')),
  amount NUMERIC NOT NULL,
  tx_hash TEXT,
  block_number INTEGER,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_transactions_pool ON transactions(pool_id);
CREATE INDEX idx_transactions_address ON transactions(address);
CREATE INDEX idx_transactions_type ON transactions(tx_type);

-- ============================================
-- USER PROFILES (optional metadata)
-- ============================================
CREATE TABLE profiles (
  address TEXT PRIMARY KEY,
  display_name TEXT,
  avatar_url TEXT,
  telegram_id TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================
-- NOTIFICATIONS
-- ============================================
CREATE TABLE notifications (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  address TEXT NOT NULL,
  pool_id UUID REFERENCES pools(id) ON DELETE CASCADE,
  type TEXT NOT NULL, -- 'NEW_REQUEST', 'VOTE_ENDING', 'REQUEST_APPROVED', etc.
  title TEXT NOT NULL,
  body TEXT,
  read BOOLEAN DEFAULT false,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_notifications_address ON notifications(address);
CREATE INDEX idx_notifications_unread ON notifications(address, read) WHERE read = false;

-- ============================================
-- ROW LEVEL SECURITY
-- ============================================

-- Enable RLS on all tables
ALTER TABLE pools ENABLE ROW LEVEL SECURITY;
ALTER TABLE members ENABLE ROW LEVEL SECURITY;
ALTER TABLE requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE votes ENABLE ROW LEVEL SECURITY;
ALTER TABLE transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE notifications ENABLE ROW LEVEL SECURITY;

-- Public read access (blockchain data is public anyway)
CREATE POLICY "Public read pools" ON pools FOR SELECT USING (true);
CREATE POLICY "Public read members" ON members FOR SELECT USING (true);
CREATE POLICY "Public read requests" ON requests FOR SELECT USING (true);
CREATE POLICY "Public read votes" ON votes FOR SELECT USING (true);
CREATE POLICY "Public read transactions" ON transactions FOR SELECT USING (true);
CREATE POLICY "Public read profiles" ON profiles FOR SELECT USING (true);

-- Notifications only visible to owner (would need auth)
CREATE POLICY "Own notifications" ON notifications FOR SELECT USING (true); -- Adjust when auth is added

-- Service role can do everything (for backend indexer)
-- The service_role key bypasses RLS automatically
