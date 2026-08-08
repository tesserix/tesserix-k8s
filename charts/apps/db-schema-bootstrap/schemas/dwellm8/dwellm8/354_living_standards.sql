-- ---------------------------------------------------------------------------
-- The living standards a property must pass before it is let (#342)
-- ---------------------------------------------------------------------------
--
-- Steps on the platform's owner_onboarding template rather than a second
-- mechanism: ADR-0032 §2 already resolves a firm's own template over the
-- library, so a firm wanting a stricter list edits one thing.
--
-- The safety lines are blocking, which is what stops a handover — a checklist
-- with a blocking step outstanding cannot complete. Clause 8.3 of the
-- management agreement (#340) is the warranty they discharge: the flat is fit
-- for occupation, with safe wiring, before anyone moves into it.
--
-- Written inside the same NO FORCE window chapter 260 explains: the bootstrap
-- connects as the table owner, FORCE row-level security applies to the owner,
-- and no app.tenant_id is set, so every policy here would evaluate false.

DO $$
DECLARE
    platform_org     constant uuid := '00000000-0000-0000-0000-0000000000d8';
    owner_onboarding constant uuid := 'd8000000-0000-0000-0000-000000000003';
BEGIN
    -- The parent too: a step's is_default is denormalised by a trigger that
    -- reads checklist_templates as the invoker, and under FORCE that read
    -- returns nothing and the step lands with a null.
    ALTER TABLE checklist_templates      NO FORCE ROW LEVEL SECURITY;
    ALTER TABLE checklist_template_steps NO FORCE ROW LEVEL SECURITY;

    INSERT INTO checklist_template_steps
        (template_id, tenant_id, code, title, description, position, blocking, owner_role, due_offset_days, depends_on)
    VALUES
      (owner_onboarding, platform_org, 'pest_termite',      'Pest and termite inspection',
       'Inspection carried out and any treatment certified, with the certificate on file.',
       7,  true,  'field_agent', 5, '{portfolio_loaded}'),
      (owner_onboarding, platform_org, 'electrical_safety', 'Electrical installation safe',
       'Wiring, earthing and residual-current protection tested; no exposed or temporary wiring. PMA 8.3.',
       8,  true,  'field_agent', 5, '{portfolio_loaded}'),
      (owner_onboarding, platform_org, 'water_sanitation',  'Water, tanks and sanitation working',
       'Supply and pressure checked, tanks cleaned, drainage and sanitary fittings working.',
       9,  true,  'field_agent', 5, '{portfolio_loaded}'),
      (owner_onboarding, platform_org, 'fire_safety',       'Fire safety checked',
       'Extinguisher in date, alarm working, escape route and exit access clear.',
       10, true,  'field_agent', 5, '{portfolio_loaded}'),
      (owner_onboarding, platform_org, 'structure_damp',    'Structure, seepage and damp checked',
       'Walls, ceilings and roof inspected for seepage, damp and cracks; the owner carries structural repair. PMA 6.',
       11, false, 'field_agent', 5, '{portfolio_loaded}'),
      (owner_onboarding, platform_org, 'dues_cleared',      'Property tax, society dues and utilities cleared',
       'Nothing outstanding that would follow the incoming tenant.',
       12, true,  'accountant',  5, '{portfolio_loaded}'),
      (owner_onboarding, platform_org, 'keys_warranties',   'Keys, inventory and warranties logged',
       'Keys and access cards counted, fittings inventoried, appliance warranties recorded.',
       13, false, 'staff',       5, '{portfolio_loaded}')
    ON CONFLICT (template_id, code) DO NOTHING;

    -- Check the graph now rather than at commit: ALTER TABLE refuses to run
    -- while a deferred trigger is pending, and leaving these NO FORCE would
    -- turn row-level security off, quietly, for everybody.
    SET CONSTRAINTS checklist_template_steps_sound IMMEDIATE;

    ALTER TABLE checklist_template_steps FORCE ROW LEVEL SECURITY;
    ALTER TABLE checklist_templates      FORCE ROW LEVEL SECURITY;
END
$$;
