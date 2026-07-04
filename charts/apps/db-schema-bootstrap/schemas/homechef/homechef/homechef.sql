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
  ('cuisine', 'healthy',        'Healthy & Diet', 63),
  -- Allergies
  ('allergy', 'peanut',         'Peanut',         1),
  ('allergy', 'tree-nut',       'Tree Nut',       2),
  ('allergy', 'shellfish',      'Shellfish',       3),
  ('allergy', 'fish',           'Fish',            4),
  ('allergy', 'dairy',          'Dairy',           5),
  ('allergy', 'egg',            'Egg',             6),
  ('allergy', 'sesame',         'Sesame',          7),
  ('allergy', 'soy',            'Soy',             8),
  ('allergy', 'gluten',         'Gluten',          9),
  ('allergy', 'mustard',        'Mustard',         10),
  -- Spice levels
  ('spice_level', 'mild',       'Mild',            1),
  ('spice_level', 'low',        'Low',             2),
  ('spice_level', 'medium',     'Medium',          3),
  ('spice_level', 'high',       'High',            4),
  ('spice_level', 'very-high',  'Very High',       5),
  -- Household size
  ('household_size', '1',       '1 Person',        1),
  ('household_size', '2',       '2 People',        2),
  ('household_size', '3',       '3 People',        3),
  ('household_size', '4',       '4 People',        4),
  ('household_size', '5',       '5 People',        5),
  ('household_size', '6+',      '6+ People',       6)
) AS v(category, value, label, sort_order)
WHERE NOT EXISTS (
  SELECT 1 FROM preference_options po
  WHERE po.category = v.category AND po.value = v.value
);

-- ---------------------------------------------------------------------------
-- 6. Seed exchange rates (base: INR)
--    Model: ExchangeRate { id uuid PK, base_currency, target_currency, rate, fetched_at, created_at }
--    Unique index: idx_rate_pair (base_currency, target_currency)
-- ---------------------------------------------------------------------------
INSERT INTO exchange_rates (id, base_currency, target_currency, rate, fetched_at, created_at)
VALUES
  (gen_random_uuid(), 'INR', 'INR', 1.0000,    NOW(), NOW()),
  (gen_random_uuid(), 'INR', 'USD', 0.01190,   NOW(), NOW()),
  (gen_random_uuid(), 'INR', 'GBP', 0.00940,   NOW(), NOW()),
  (gen_random_uuid(), 'INR', 'EUR', 0.01090,   NOW(), NOW()),
  (gen_random_uuid(), 'INR', 'AED', 0.04370,   NOW(), NOW()),
  (gen_random_uuid(), 'INR', 'SGD', 0.01590,   NOW(), NOW()),
  (gen_random_uuid(), 'INR', 'AUD', 0.01830,   NOW(), NOW()),
  (gen_random_uuid(), 'INR', 'CAD', 0.01620,   NOW(), NOW()),
  (gen_random_uuid(), 'INR', 'MYR', 0.05290,   NOW(), NOW()),
  (gen_random_uuid(), 'INR', 'PKR', 3.31000,   NOW(), NOW()),
  (gen_random_uuid(), 'INR', 'BDT', 1.30000,   NOW(), NOW()),
  (gen_random_uuid(), 'INR', 'NPR', 1.60000,   NOW(), NOW()),
  (gen_random_uuid(), 'INR', 'LKR', 3.60000,   NOW(), NOW()),
  (gen_random_uuid(), 'INR', 'IDR', 188.00000, NOW(), NOW()),
  (gen_random_uuid(), 'INR', 'VND', 302.00000, NOW(), NOW()),
  (gen_random_uuid(), 'INR', 'THB', 0.41000,   NOW(), NOW()),
  (gen_random_uuid(), 'INR', 'PHP', 0.67000,   NOW(), NOW()),
  (gen_random_uuid(), 'INR', 'JPY', 1.78000,   NOW(), NOW()),
  (gen_random_uuid(), 'INR', 'KRW', 16.30000,  NOW(), NOW()),
  (gen_random_uuid(), 'INR', 'SAR', 0.04460,   NOW(), NOW()),
  (gen_random_uuid(), 'INR', 'NZD', 0.01980,   NOW(), NOW())
ON CONFLICT (base_currency, target_currency) DO UPDATE SET rate = EXCLUDED.rate, fetched_at = NOW();

-- ---------------------------------------------------------------------------
-- 7. Seed major Indian cities with delivery zones
--    Cities need state_id FK — look up by state code
-- ---------------------------------------------------------------------------
-- Major cities
INSERT INTO cities (id, state_id, name, is_major, latitude, longitude, is_active, created_at)
SELECT gen_random_uuid(), s.id, v.name, v.is_major, v.lat, v.lng, true, NOW()
FROM (VALUES
  ('KA', 'Bangalore',       true,  12.9716, 77.5946),
  ('KA', 'Mysore',          false, 12.2958, 76.6394),
  ('MH', 'Mumbai',          true,  19.0760, 72.8777),
  ('MH', 'Pune',            true,  18.5204, 73.8567),
  ('MH', 'Nagpur',          false, 21.1458, 79.0882),
  ('DL', 'New Delhi',       true,  28.6139, 77.2090),
  ('TN', 'Chennai',         true,  13.0827, 80.2707),
  ('TN', 'Coimbatore',      false, 11.0168, 76.9558),
  ('KL', 'Kochi',           true,  9.9312,  76.2673),
  ('KL', 'Thiruvananthapuram', false, 8.5241, 76.9366),
  ('TS', 'Hyderabad',       true,  17.3850, 78.4867),
  ('AP', 'Visakhapatnam',   false, 17.6868, 83.2185),
  ('WB', 'Kolkata',         true,  22.5726, 88.3639),
  ('GJ', 'Ahmedabad',       true,  23.0225, 72.5714),
  ('GJ', 'Surat',           false, 21.1702, 72.8311),
  ('RJ', 'Jaipur',          true,  26.9124, 75.7873),
  ('UP', 'Lucknow',         true,  26.8467, 80.9462),
  ('UP', 'Noida',           false, 28.5355, 77.3910),
  ('UP', 'Varanasi',        false, 25.3176, 83.0063),
  ('OR', 'Bhubaneswar',     true,  20.2961, 85.8245),
  ('OR', 'Cuttack',         false, 20.4625, 85.8830),
  ('PB', 'Chandigarh',      true,  30.7333, 76.7794),
  ('HR', 'Gurugram',        true,  28.4595, 77.0266),
  ('GA', 'Panaji',          false, 15.4909, 73.8278),
  ('BR', 'Patna',           false, 25.6093, 85.1376),
  ('JH', 'Ranchi',          false, 23.3441, 85.3096),
  ('CT', 'Raipur',          false, 21.2514, 81.6296),
  ('AS', 'Guwahati',        false, 26.1445, 91.7362),
  ('CH', 'Chandigarh City', false, 30.7333, 76.7794),
  ('MP', 'Bhopal',          false, 23.2599, 77.4126),
  ('MP', 'Indore',          false, 22.7196, 75.8577)
) AS v(state_code, name, is_major, lat, lng)
JOIN states s ON s.code = v.state_code
JOIN countries c ON c.id = s.country_id AND c.code = 'IN'
WHERE NOT EXISTS (
  SELECT 1 FROM cities ci WHERE ci.state_id = s.id AND ci.name = v.name
);

-- ---------------------------------------------------------------------------
-- 8. Seed delivery zones for major Indian cities
--    One zone per major city with standard pricing
-- ---------------------------------------------------------------------------
INSERT INTO delivery_zones (id, name, city, state, country, tier, currency, base_fare, per_km_rate, minimum_fare, surge_multiplier, tip_enabled, default_tip_percent, max_tip_amount, driver_payout_percent, is_active, created_at, updated_at)
SELECT gen_random_uuid(), v.name || ' Zone', v.city, v.state, 'IN', v.tier, 'INR',
       v.base_fare, v.per_km_rate, v.min_fare, 1.0, true, 10, 500, 100, true, NOW(), NOW()
FROM (VALUES
  ('Bangalore Metro',    'Bangalore',    'Karnataka',       'metro',    25, 8, 35),
  ('Mumbai Metro',       'Mumbai',       'Maharashtra',     'metro',    30, 10, 40),
  ('Delhi NCR',          'New Delhi',    'Delhi',           'metro',    25, 9, 35),
  ('Chennai Metro',      'Chennai',      'Tamil Nadu',      'metro',    22, 7, 30),
  ('Hyderabad Metro',    'Hyderabad',    'Telangana',       'metro',    22, 7, 30),
  ('Kolkata Metro',      'Kolkata',      'West Bengal',     'metro',    20, 6, 28),
  ('Pune City',          'Pune',         'Maharashtra',     'mid_tier', 20, 7, 28),
  ('Ahmedabad City',     'Ahmedabad',    'Gujarat',         'mid_tier', 18, 6, 25),
  ('Jaipur City',        'Jaipur',       'Rajasthan',       'mid_tier', 18, 6, 25),
  ('Lucknow City',       'Lucknow',      'Uttar Pradesh',   'mid_tier', 18, 6, 25),
  ('Kochi City',         'Kochi',        'Kerala',          'mid_tier', 20, 7, 28),
  ('Bhubaneswar City',   'Bhubaneswar',  'Odisha',          'standard', 15, 5, 22),
  ('Noida City',         'Noida',        'Uttar Pradesh',   'mid_tier', 22, 8, 30),
  ('Gurugram City',      'Gurugram',     'Haryana',         'mid_tier', 22, 8, 30),
  ('Coimbatore City',    'Coimbatore',   'Tamil Nadu',      'standard', 15, 5, 22),
  ('Surat City',         'Surat',        'Gujarat',         'standard', 15, 5, 22),
  ('Indore City',        'Indore',       'Madhya Pradesh',  'standard', 15, 5, 22),
  ('Mysore City',        'Mysore',       'Karnataka',       'standard', 15, 5, 22)
) AS v(name, city, state, tier, base_fare, per_km_rate, min_fare)
WHERE NOT EXISTS (
  SELECT 1 FROM delivery_zones dz WHERE dz.city = v.city AND dz.country = 'IN' AND dz.deleted_at IS NULL
);

-- ---------------------------------------------------------------------------
-- 9. Seed platform settings (subscription plans, tax rates, system config)
--    These are the key-value pairs that the billing engine and admin dashboard read
-- ---------------------------------------------------------------------------
INSERT INTO platform_settings (id, key, value, type, updated_at)
VALUES
  -- India chef subscription plans (INR)
  (gen_random_uuid(), 'subscription.IN.chef.monthly_price',     '499',   'number', NOW()),
  (gen_random_uuid(), 'subscription.IN.chef.quarterly_price',   '1299',  'number', NOW()),
  (gen_random_uuid(), 'subscription.IN.chef.yearly_price',      '4499',  'number', NOW()),
  (gen_random_uuid(), 'subscription.IN.chef.trial_days',        '30',    'number', NOW()),
  (gen_random_uuid(), 'subscription.IN.chef.currency',          'INR',   'string', NOW()),
  -- India driver subscription plans (INR)
  (gen_random_uuid(), 'subscription.IN.driver.monthly_price',   '299',   'number', NOW()),
  (gen_random_uuid(), 'subscription.IN.driver.quarterly_price', '799',   'number', NOW()),
  (gen_random_uuid(), 'subscription.IN.driver.yearly_price',    '2699',  'number', NOW()),
  (gen_random_uuid(), 'subscription.IN.driver.trial_days',      '14',    'number', NOW()),
  (gen_random_uuid(), 'subscription.IN.driver.currency',        'INR',   'string', NOW()),
  (gen_random_uuid(), 'subscription.IN.driver.earnings_threshold', '3000', 'number', NOW()),
  -- Global settings
  (gen_random_uuid(), 'subscription.grace_period_days',         '7',     'number', NOW()),
  (gen_random_uuid(), 'platform.service_fee_percent',           '5',     'number', NOW()),
  (gen_random_uuid(), 'platform.tax_rate.IN',                   '18',    'number', NOW()),
  (gen_random_uuid(), 'platform.tax_rate.AE',                   '5',     'number', NOW()),
  (gen_random_uuid(), 'platform.tax_rate.SG',                   '9',     'number', NOW()),
  (gen_random_uuid(), 'platform.tax_rate.AU',                   '10',    'number', NOW()),
  (gen_random_uuid(), 'platform.tax_rate.PK',                   '17',    'number', NOW()),
  (gen_random_uuid(), 'platform.tax_rate.BD',                   '15',    'number', NOW()),
  (gen_random_uuid(), 'platform.tax_rate.LK',                   '8',     'number', NOW()),
  (gen_random_uuid(), 'platform.tax_rate.NP',                   '13',    'number', NOW()),
  (gen_random_uuid(), 'platform.tax_rate.MY',                   '6',     'number', NOW()),
  (gen_random_uuid(), 'platform.tax_rate.default',              '0',     'number', NOW()),
  -- Featured ad pricing (INR for India)
  (gen_random_uuid(), 'promotion.IN.chef.featured_monthly_price', '499', 'number', NOW()),
  (gen_random_uuid(), 'promotion.default.chef.featured_monthly_price', '9.99', 'number', NOW()),
  -- Order settings
  (gen_random_uuid(), 'order.max_items_per_order',              '50',    'number', NOW()),
  (gen_random_uuid(), 'order.default_prep_time_minutes',        '30',    'number', NOW()),
  (gen_random_uuid(), 'order.cancellation_window_minutes',      '5',     'number', NOW()),
  -- Chef settings
  (gen_random_uuid(), 'chef.max_menu_items',                    '200',   'number', NOW()),
  (gen_random_uuid(), 'chef.max_categories',                    '20',    'number', NOW()),
  (gen_random_uuid(), 'chef.max_images_per_item',               '5',     'number', NOW()),
  -- Customer settings
  (gen_random_uuid(), 'customer.max_favorites',                 '7',     'number', NOW()),
  (gen_random_uuid(), 'customer.max_addresses',                 '10',    'number', NOW()),
  -- Support settings
  (gen_random_uuid(), 'support.auto_close_days',                '7',     'number', NOW()),
  (gen_random_uuid(), 'support.sla_response_hours',             '24',    'number', NOW())
ON CONFLICT (key) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 4. Email verification tokens table
--    Used by the Go API's email verification flow. GORM AutoMigrate also
--    creates this table at API startup; this DDL is belt-and-suspenders so
--    the schema exists even before the first API pod starts.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS email_verification_tokens (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token           VARCHAR(255) NOT NULL,
  used_at         TIMESTAMPTZ,
  expires_at      TIMESTAMPTZ NOT NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_email_verification_tokens_token
  ON email_verification_tokens (token);

CREATE INDEX IF NOT EXISTS idx_email_verification_tokens_user_id
  ON email_verification_tokens (user_id);

-- ---------------------------------------------------------------------------
-- 5. Staff invitations table (if not already created by GORM)
--    Tracks token-based staff invitations with 7-day expiry and role assignment.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS staff_invitations (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email           VARCHAR(255) NOT NULL,
  staff_role      VARCHAR(50) NOT NULL DEFAULT 'support',
  department      VARCHAR(100),
  title           VARCHAR(100),
  token           VARCHAR(255) NOT NULL,
  status          VARCHAR(20) NOT NULL DEFAULT 'pending',
  message         TEXT,
  invited_by_id   UUID REFERENCES users(id),
  accepted_by_id  UUID REFERENCES users(id),
  expires_at      TIMESTAMPTZ NOT NULL,
  accepted_at     TIMESTAMPTZ,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_staff_invitations_token
  ON staff_invitations (token);

CREATE INDEX IF NOT EXISTS idx_staff_invitations_email
  ON staff_invitations (email);

-- ---------------------------------------------------------------------------
-- 6. Staff members table (if not already created by GORM)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS staff_members (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  staff_role      VARCHAR(50) NOT NULL DEFAULT 'support',
  department      VARCHAR(100),
  title           VARCHAR(100),
  is_active       BOOLEAN NOT NULL DEFAULT true,
  deactivated_at  TIMESTAMPTZ,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_staff_members_user_id
  ON staff_members (user_id);

CREATE INDEX IF NOT EXISTS idx_staff_members_role
  ON staff_members (staff_role);

-- ---------------------------------------------------------------------------
-- 7. Reliable event backbone — transactional outbox + consumer idempotency
--    Models: apps/api/models/outbox.go, processed_event.go
--    The API stages domain events in outbox_events inside the same transaction
--    as the business write; the OutboxRelay publishes them to JetStream with
--    PubAck. processed_events dedups at-least-once consumer redelivery.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS outbox_events (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  subject         VARCHAR(255) NOT NULL,
  msg_id          VARCHAR(64) NOT NULL,
  aggregate_type  VARCHAR(64),
  aggregate_id    VARCHAR(64),
  payload         TEXT NOT NULL,
  status          VARCHAR(16) NOT NULL DEFAULT 'pending',
  attempts        INTEGER NOT NULL DEFAULT 0,
  last_error      TEXT,
  next_retry_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  published_at    TIMESTAMPTZ
);

-- One row per event; the msg_id is also the Nats-Msg-Id used for dedup.
CREATE UNIQUE INDEX IF NOT EXISTS idx_outbox_events_msg_id
  ON outbox_events (msg_id);

-- Hot path: the relay claims due, pending rows oldest-first.
CREATE INDEX IF NOT EXISTS idx_outbox_dispatch
  ON outbox_events (status, next_retry_at);

CREATE INDEX IF NOT EXISTS idx_outbox_events_aggregate
  ON outbox_events (aggregate_type, aggregate_id);

CREATE TABLE IF NOT EXISTS processed_events (
  consumer      VARCHAR(64) NOT NULL,
  msg_id        VARCHAR(64) NOT NULL,
  subject       VARCHAR(255),
  processed_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (consumer, msg_id)
);

CREATE INDEX IF NOT EXISTS idx_processed_events_processed_at
  ON processed_events (processed_at);

-- Cancellation with vendor arbitration + tiered refund (Home-Chef-App #475).
-- One request per order; the vendor picks a reason that selects a food-refund
-- tier. The refund breakdown is a paise SNAPSHOT computed when the tier is
-- decided; the platform fee is always in platform_kept_paise (nonrefundable).
CREATE TABLE IF NOT EXISTS cancellation_requests (
  id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id             UUID NOT NULL,
  customer_id          UUID NOT NULL,
  chef_id              UUID NOT NULL,
  status               VARCHAR(24) NOT NULL DEFAULT 'pending_vendor',
  customer_reason      TEXT,
  vendor_reason        VARCHAR(32),
  refund_destination   VARCHAR(16),
  food_refund_paise     INTEGER NOT NULL DEFAULT 0,
  delivery_refund_paise INTEGER NOT NULL DEFAULT 0,
  tax_refund_paise      INTEGER NOT NULL DEFAULT 0,
  refund_total_paise    INTEGER NOT NULL DEFAULT 0,
  vendor_kept_paise     INTEGER NOT NULL DEFAULT 0,
  platform_kept_paise   INTEGER NOT NULL DEFAULT 0,
  refund_executed      BOOLEAN NOT NULL DEFAULT FALSE,
  refund_ref           VARCHAR(64),
  disputed             BOOLEAN NOT NULL DEFAULT FALSE,
  dispute_reason       TEXT,
  admin_resolved_by    UUID,
  admin_note           TEXT,
  vendor_respond_by    TIMESTAMPTZ,
  resolved_at          TIMESTAMPTZ,
  created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at           TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_cancellation_requests_order
  ON cancellation_requests (order_id);
CREATE INDEX IF NOT EXISTS idx_cancellation_requests_chef_status
  ON cancellation_requests (chef_id, status);
CREATE INDEX IF NOT EXISTS idx_cancellation_requests_customer
  ON cancellation_requests (customer_id);
-- The timeout sweep scans pending requests past their deadline.
CREATE INDEX IF NOT EXISTS idx_cancellation_requests_pending_deadline
  ON cancellation_requests (status, vendor_respond_by);
