from pathlib import Path
import yaml

ROOT = Path(__file__).resolve().parents[1]


def test_onboarding_authorizes_only_its_kargo_stage():
    app = yaml.safe_load((ROOT / 'argocd/prod/apps/platform/onboarding-service.yaml').read_text())
    assert app['metadata']['annotations']['kargo.akuity.io/authorized-stage'] == 'kargo-onboarding:prod'
    params = {p['name']: p['value'] for p in app['spec']['source']['helm']['parameters']}
    assert set(params) == {'api.image.tag', 'web.image.tag'}
    assert all(params.values())


def test_platform_parent_preserves_only_onboarding_promotion_parameters():
    app = yaml.safe_load((ROOT / 'argocd/prod/apps/platform-app-of-apps.yaml').read_text())
    rules = app['spec']['ignoreDifferences']
    rule = next(r for r in rules if r.get('name') == 'onboarding-service')
    assert rule['kind'] == 'Application'
    assert rule['group'] == 'argoproj.io'
    assert rule['namespace'] == 'argocd'
    assert rule['jsonPointers'] == ['/spec/source/helm/parameters']
    assert 'RespectIgnoreDifferences=true' in app['spec']['syncPolicy']['syncOptions']
