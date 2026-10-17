import pathlib
import subprocess
import unittest
import yaml

ROOT=pathlib.Path(__file__).resolve().parents[1]
def render(chart, *args):
    return [d for d in yaml.safe_load_all(subprocess.check_output(['helm','template','test',str(ROOT/'charts/apps'/chart),'--namespace','tesserix',*args],text=True)) if d]
class ConsoleIdentityOnboarding(unittest.TestCase):
    def test_console_calls_private_api_and_api_pins_console_identity(self):
        values=yaml.safe_load((ROOT/'charts/apps/console/values.yaml').read_text())
        self.assertEqual(values['env']['ONBOARDING_API_ORIGIN'],'http://onboarding-api.onboarding.svc.cluster.local:8080')
        docs=render('onboarding-service','-f',str(ROOT/'charts/apps/onboarding-service/values-prod.yaml'))
        api=next(d for d in docs if d['kind']=='Deployment' and d['metadata']['name']=='onboarding-api')
        env={e['name']:e.get('value') for e in api['spec']['template']['spec']['containers'][0]['env']}
        self.assertEqual(env['CONSOLE_PROJECT_ID'],'386377618200461939')
        self.assertEqual(env['CONSOLE_CLIENT_ID'],'386382971877196703')
        policy=next(d for d in docs if d['kind']=='NetworkPolicy' and d['metadata']['name']=='allow-console-onboarding')
        peer=policy['spec']['ingress'][0]['from'][0]
        self.assertEqual(peer['namespaceSelector']['matchLabels']['kubernetes.io/metadata.name'],'tesserix')
        self.assertEqual(peer['podSelector']['matchLabels']['app.kubernetes.io/name'],'console')

    def test_product_machine_api_uses_console_origin_without_browser_middleware(self):
        docs=render('console')
        vs=next(d for d in docs if d['kind']=='VirtualService')
        self.assertEqual(vs['spec']['hosts'],['console.tesserix.app'])
        machine=vs['spec']['http'][0]
        self.assertEqual(machine['match'],[{'uri':{'prefix':'/v1/'}}])
        self.assertEqual(machine['route'][0]['destination'],{'host':'onboarding-api.onboarding.svc.cluster.local','port':{'number':8080}})
        self.assertNotIn('rewrite',machine)
        self.assertNotIn('headers',machine)
        self.assertNotIn('match',vs['spec']['http'][-1])
