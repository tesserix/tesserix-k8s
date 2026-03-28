-- =============================================================================
-- HomeChef DB Bootstrap — permissions + reference data seed
-- Idempotent: safe to run repeatedly via CronJob
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Permissions — grant homechef user full access to public schema
-- ---------------------------------------------------------------------------
GRANT ALL ON SCHEMA public TO homechef;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO homechef;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO homechef;

-- Grant on any tables/sequences that already exist
GRANT ALL ON ALL TABLES IN SCHEMA public TO homechef;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO homechef;

-- ---------------------------------------------------------------------------
-- 2. Seed currencies
--    Model: Currency { id uuid PK, code varchar(3) UNIQUE, name, symbol, decimal_places, is_active, created_at }
-- ---------------------------------------------------------------------------
INSERT INTO currencies (id, code, name, symbol, decimal_places, is_active, created_at)
VALUES
  -- Major currencies
  (gen_random_uuid(), 'INR', 'Indian Rupee',           '₹',   2, true, NOW()),
  (gen_random_uuid(), 'USD', 'US Dollar',              '$',   2, true, NOW()),
  (gen_random_uuid(), 'GBP', 'British Pound',          '£',   2, true, NOW()),
  (gen_random_uuid(), 'EUR', 'Euro',                   '€',   2, true, NOW()),
  (gen_random_uuid(), 'AED', 'UAE Dirham',             'د.إ', 2, true, NOW()),
  (gen_random_uuid(), 'SGD', 'Singapore Dollar',       'S$',  2, true, NOW()),
  (gen_random_uuid(), 'AUD', 'Australian Dollar',      'A$',  2, true, NOW()),
  (gen_random_uuid(), 'CAD', 'Canadian Dollar',        'C$',  2, true, NOW()),
  -- Asian currencies
  (gen_random_uuid(), 'MYR', 'Malaysian Ringgit',      'RM',  2, true, NOW()),
  (gen_random_uuid(), 'PKR', 'Pakistani Rupee',        '₨',   2, true, NOW()),
  (gen_random_uuid(), 'BDT', 'Bangladeshi Taka',       '৳',   2, true, NOW()),
  (gen_random_uuid(), 'NPR', 'Nepalese Rupee',         'रू',  2, true, NOW()),
  (gen_random_uuid(), 'BTN', 'Bhutanese Ngultrum',     'Nu',  2, true, NOW()),
  (gen_random_uuid(), 'LKR', 'Sri Lankan Rupee',       'Rs',  2, true, NOW()),
  (gen_random_uuid(), 'IDR', 'Indonesian Rupiah',      'Rp',  0, true, NOW()),
  (gen_random_uuid(), 'VND', 'Vietnamese Dong',        '₫',   0, true, NOW()),
  (gen_random_uuid(), 'THB', 'Thai Baht',              '฿',   2, true, NOW()),
  (gen_random_uuid(), 'PHP', 'Philippine Peso',        '₱',   2, true, NOW()),
  (gen_random_uuid(), 'MMK', 'Myanmar Kyat',           'K',   0, true, NOW()),
  (gen_random_uuid(), 'KHR', 'Cambodian Riel',         '៛',   2, true, NOW()),
  (gen_random_uuid(), 'LAK', 'Lao Kip',               '₭',   0, true, NOW()),
  (gen_random_uuid(), 'KRW', 'South Korean Won',       '₩',   0, true, NOW()),
  (gen_random_uuid(), 'JPY', 'Japanese Yen',           '¥',   0, true, NOW()),
  (gen_random_uuid(), 'CNY', 'Chinese Yuan',           '¥',   2, true, NOW()),
  (gen_random_uuid(), 'TWD', 'Taiwan Dollar',          'NT$', 2, true, NOW()),
  (gen_random_uuid(), 'HKD', 'Hong Kong Dollar',       'HK$', 2, true, NOW()),
  -- Middle East
  (gen_random_uuid(), 'SAR', 'Saudi Riyal',            '﷼',   2, true, NOW()),
  (gen_random_uuid(), 'QAR', 'Qatari Riyal',           '﷼',   2, true, NOW()),
  (gen_random_uuid(), 'BHD', 'Bahraini Dinar',         'BD',  3, true, NOW()),
  (gen_random_uuid(), 'KWD', 'Kuwaiti Dinar',          'KD',  3, true, NOW()),
  (gen_random_uuid(), 'OMR', 'Omani Rial',             'OMR', 3, true, NOW()),
  (gen_random_uuid(), 'NZD', 'New Zealand Dollar',    'NZ$', 2, true, NOW())
ON CONFLICT (code) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 3. Seed countries
--    Model: Country { id uuid PK, code varchar(3) UNIQUE, name, phone_code, currency_code, currency_symbol, is_active, created_at }
-- ---------------------------------------------------------------------------
INSERT INTO countries (id, code, name, phone_code, currency_code, currency_symbol, is_active, created_at)
VALUES
  -- South Asia
  (gen_random_uuid(), 'IN', 'India',                   '+91',   'INR', '₹',   true, NOW()),
  (gen_random_uuid(), 'PK', 'Pakistan',                '+92',   'PKR', '₨',   true, NOW()),
  (gen_random_uuid(), 'BD', 'Bangladesh',              '+880',  'BDT', '৳',   true, NOW()),
  (gen_random_uuid(), 'NP', 'Nepal',                   '+977',  'NPR', 'रू',  true, NOW()),
  (gen_random_uuid(), 'BT', 'Bhutan',                  '+975',  'BTN', 'Nu',  true, NOW()),
  (gen_random_uuid(), 'LK', 'Sri Lanka',               '+94',   'LKR', 'Rs',  true, NOW()),
  (gen_random_uuid(), 'MV', 'Maldives',                '+960',  'USD', '$',   true, NOW()),
  -- Southeast Asia
  (gen_random_uuid(), 'MY', 'Malaysia',                '+60',   'MYR', 'RM',  true, NOW()),
  (gen_random_uuid(), 'SG', 'Singapore',               '+65',   'SGD', 'S$',  true, NOW()),
  (gen_random_uuid(), 'ID', 'Indonesia',               '+62',   'IDR', 'Rp',  true, NOW()),
  (gen_random_uuid(), 'VN', 'Vietnam',                 '+84',   'VND', '₫',   true, NOW()),
  (gen_random_uuid(), 'TH', 'Thailand',                '+66',   'THB', '฿',   true, NOW()),
  (gen_random_uuid(), 'PH', 'Philippines',             '+63',   'PHP', '₱',   true, NOW()),
  (gen_random_uuid(), 'MM', 'Myanmar',                 '+95',   'MMK', 'K',   true, NOW()),
  (gen_random_uuid(), 'KH', 'Cambodia',                '+855',  'KHR', '៛',   true, NOW()),
  (gen_random_uuid(), 'LA', 'Laos',                    '+856',  'LAK', '₭',   true, NOW()),
  -- East Asia
  (gen_random_uuid(), 'JP', 'Japan',                   '+81',   'JPY', '¥',   true, NOW()),
  (gen_random_uuid(), 'KR', 'South Korea',             '+82',   'KRW', '₩',   true, NOW()),
  (gen_random_uuid(), 'CN', 'China',                   '+86',   'CNY', '¥',   true, NOW()),
  (gen_random_uuid(), 'TW', 'Taiwan',                  '+886',  'TWD', 'NT$', true, NOW()),
  (gen_random_uuid(), 'HK', 'Hong Kong',               '+852',  'HKD', 'HK$', true, NOW()),
  -- Middle East
  (gen_random_uuid(), 'AE', 'United Arab Emirates',    '+971',  'AED', 'د.إ', true, NOW()),
  (gen_random_uuid(), 'SA', 'Saudi Arabia',            '+966',  'SAR', '﷼',   true, NOW()),
  (gen_random_uuid(), 'QA', 'Qatar',                   '+974',  'QAR', '﷼',   true, NOW()),
  (gen_random_uuid(), 'BH', 'Bahrain',                 '+973',  'BHD', 'BD',  true, NOW()),
  (gen_random_uuid(), 'KW', 'Kuwait',                  '+965',  'KWD', 'KD',  true, NOW()),
  (gen_random_uuid(), 'OM', 'Oman',                    '+968',  'OMR', 'OMR', true, NOW()),
  -- Western
  (gen_random_uuid(), 'US', 'United States',           '+1',    'USD', '$',   true, NOW()),
  (gen_random_uuid(), 'GB', 'United Kingdom',          '+44',   'GBP', '£',   true, NOW()),
  (gen_random_uuid(), 'AU', 'Australia',               '+61',   'AUD', 'A$',  true, NOW()),
  (gen_random_uuid(), 'CA', 'Canada',                  '+1',    'CAD', 'C$',  true, NOW()),
  (gen_random_uuid(), 'NZ', 'New Zealand',             '+64',   'NZD', 'NZ$', true, NOW())
ON CONFLICT (code) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 4. Seed Indian states
--    Model: State { id uuid PK, country_id uuid FK, code varchar(10), name, is_active, created_at }
--    Unique index: idx_state_country_code (country_id, code)
--    country_id is a UUID FK — look up India's id from countries table
-- ---------------------------------------------------------------------------
INSERT INTO states (id, country_id, code, name, is_active, created_at)
SELECT gen_random_uuid(), c.id, v.code, v.name, true, NOW()
FROM (VALUES
  -- All 28 Indian states
  ('AP', 'Andhra Pradesh'),
  ('AR', 'Arunachal Pradesh'),
  ('AS', 'Assam'),
  ('BR', 'Bihar'),
  ('CT', 'Chhattisgarh'),
  ('GA', 'Goa'),
  ('GJ', 'Gujarat'),
  ('HR', 'Haryana'),
  ('HP', 'Himachal Pradesh'),
  ('JH', 'Jharkhand'),
  ('KA', 'Karnataka'),
  ('KL', 'Kerala'),
  ('MP', 'Madhya Pradesh'),
  ('MH', 'Maharashtra'),
  ('MN', 'Manipur'),
  ('ML', 'Meghalaya'),
  ('MZ', 'Mizoram'),
  ('NL', 'Nagaland'),
  ('OR', 'Odisha'),
  ('PB', 'Punjab'),
  ('RJ', 'Rajasthan'),
  ('SK', 'Sikkim'),
  ('TN', 'Tamil Nadu'),
  ('TS', 'Telangana'),
  ('TR', 'Tripura'),
  ('UP', 'Uttar Pradesh'),
  ('UK', 'Uttarakhand'),
  ('WB', 'West Bengal'),
  -- 8 Union Territories
  ('AN', 'Andaman & Nicobar Islands'),
  ('CH', 'Chandigarh'),
  ('DN', 'Dadra & Nagar Haveli and Daman & Diu'),
  ('DL', 'Delhi'),
  ('JK', 'Jammu & Kashmir'),
  ('LA', 'Ladakh'),
  ('LD', 'Lakshadweep'),
  ('PY', 'Puducherry')
) AS v(code, name)
CROSS JOIN countries c
WHERE c.code = 'IN'
  AND NOT EXISTS (
    SELECT 1 FROM states s WHERE s.country_id = c.id AND s.code = v.code
  );

-- ---------------------------------------------------------------------------
-- 5. Seed preference options (dietary, cuisine)
--    Model: PreferenceOption { id uuid PK, category, value, label, description, sort_order, is_active, created_at }
--    No unique constraint on (category, value) — use NOT EXISTS for idempotency
-- ---------------------------------------------------------------------------
INSERT INTO preference_options (id, category, value, label, sort_order, is_active, created_at)
SELECT gen_random_uuid(), v.category, v.value, v.label, v.sort_order, true, NOW()
FROM (VALUES
  ('dietary', 'vegetarian',     'Vegetarian',     1),
  ('dietary', 'vegan',          'Vegan',          2),
  ('dietary', 'non-vegetarian', 'Non-Vegetarian', 3),
  ('dietary', 'eggetarian',     'Eggetarian',     4),
  ('dietary', 'jain',           'Jain',           5),
  ('dietary', 'gluten-free',    'Gluten Free',    6),
  ('dietary', 'halal',          'Halal',          7),
  -- Indian cuisines
  ('cuisine', 'south-indian',   'South Indian',   1),
  ('cuisine', 'north-indian',   'North Indian',   2),
  ('cuisine', 'bengali',        'Bengali',        3),
  ('cuisine', 'odia',           'Odia',           4),
  ('cuisine', 'gujarati',       'Gujarati',       5),
  ('cuisine', 'rajasthani',     'Rajasthani',     6),
  ('cuisine', 'punjabi',        'Punjabi',        7),
  ('cuisine', 'maharashtrian',  'Maharashtrian',  8),
  ('cuisine', 'kerala',         'Kerala',         9),
  ('cuisine', 'hyderabadi',     'Hyderabadi',     10),
  ('cuisine', 'mughlai',        'Mughlai',        11),
  ('cuisine', 'chettinad',      'Chettinad',      12),
  ('cuisine', 'kashmiri',       'Kashmiri',       13),
  ('cuisine', 'assamese',       'Assamese',       14),
  ('cuisine', 'goan',           'Goan',           15),
  -- Asian cuisines
  ('cuisine', 'chinese',        'Chinese',        20),
  ('cuisine', 'thai',           'Thai',           21),
  ('cuisine', 'japanese',       'Japanese',       22),
  ('cuisine', 'korean',         'Korean',         23),
  ('cuisine', 'vietnamese',     'Vietnamese',     24),
  ('cuisine', 'indonesian',     'Indonesian',     25),
  ('cuisine', 'malaysian',      'Malaysian',      26),
  ('cuisine', 'filipino',       'Filipino',       27),
  ('cuisine', 'burmese',        'Burmese',        28),
  ('cuisine', 'nepali',         'Nepali',         29),
  ('cuisine', 'sri-lankan',     'Sri Lankan',     30),
  ('cuisine', 'bangladeshi',    'Bangladeshi',    31),
  ('cuisine', 'pakistani',      'Pakistani',      32),
  -- Middle Eastern
  ('cuisine', 'arabic',         'Arabic',         40),
  ('cuisine', 'lebanese',       'Lebanese',       41),
  ('cuisine', 'turkish',        'Turkish',        42),
  ('cuisine', 'persian',        'Persian',        43),
  -- Western
  ('cuisine', 'italian',        'Italian',        50),
  ('cuisine', 'continental',    'Continental',    51),
  ('cuisine', 'mexican',        'Mexican',        52),
  ('cuisine', 'american',       'American',       53),
  ('cuisine', 'mediterranean',  'Mediterranean',  54),
  -- Other
  ('cuisine', 'street-food',    'Street Food',    60),
  ('cuisine', 'fusion',         'Fusion',         61),
  ('cuisine', 'bakery',         'Bakery & Desserts', 62),
  ('cuisine', 'healthy',        'Healthy & Diet', 63)
) AS v(category, value, label, sort_order)
WHERE NOT EXISTS (
  SELECT 1 FROM preference_options po
  WHERE po.category = v.category AND po.value = v.value
);
