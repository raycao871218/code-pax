"""Exercise the real subprocess/control transport without model/network access."""
import json
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

from bridge import Bridge
from claude_runtime import configuration
from test_bridge import FakeRPC


FAKE = r'''
import json, sys
from pathlib import Path
args = sys.argv[1:]
resume = '--resume' in args
sid = args[args.index('--resume' if resume else '--session-id') + 1]
def emit(value):
    print(json.dumps(value), flush=True)
def read():
    return json.loads(sys.stdin.readline())
init = read()
emit({'type':'control_response','response':{'subtype':'success','request_id':init['request_id'],'response':{'models':[
 {'value':'default','resolvedModel':'fixture-model','displayName':'Default','supportsEffort':True,'supportedEffortLevels':['low','high']},
 {'value':'sonnet','resolvedModel':'fixture-model','displayName':'Fixture Sonnet 1.0','supportsEffort':True,'supportedEffortLevels':['low','high']},
 {'value':'haiku','resolvedModel':'fixture-fast','displayName':'Fixture Haiku 1.0','supportsEffort':False}
]}}})
prompt = read()['message']['content']
if prompt == 'crash':
    print('fixture process failure', file=sys.stderr)
    sys.exit(7)
if prompt == 'malformed':
    print('not json', flush=True)
    sys.exit(8)
history = Path(sid + '.fixture-history')
old = history.read_text() if resume else ''
history.write_text(old + prompt + '\n')
Path(sid + '.fixture-args').write_text(json.dumps(args))
emit({'type':'system','subtype':'init','session_id':sid,'model':'fixture-model'})
if prompt == 'wait':
    command = read()
    assert command['request']['subtype'] == 'interrupt'
    emit({'type':'result','is_error':True,'errors':['interrupted']})
    sys.exit(0)
emit({'type':'stream_event','event':{'type':'message_start','message':{'id':'reply-' + str(len(old))}}})
emit({'type':'stream_event','event':{'type':'content_block_delta','index':0,'delta':{'type':'text_delta','text':'Hello '}}})
emit({'type':'stream_event','event':{'type':'content_block_delta','index':0,'delta':{'type':'text_delta','text':'Claude'}}})
emit({'type':'assistant','message':{'id':'reply-' + str(len(old)),'content':[{'type':'text','text':'Hello Claude'},
    {'type':'tool_use','id':'tool-' + str(len(old)),'name':'Bash','input':{'command':'echo fixture'}}]}})
if prompt in ['approve', 'question']:
    questions = {'questions':[{'question':'Which branch?','options':[{'label':'main','description':'Default'}]}]}
    emit({'type':'control_request','request_id':'permission','request':{'subtype':'can_use_tool',
        'tool_name':'AskUserQuestion' if prompt == 'question' else 'Bash',
        'input':questions if prompt == 'question' else {'command':'echo fixture'}}})
    response = read()['response']['response']
    Path(sid + '.fixture-approval').write_text(json.dumps(response))
emit({'type':'user','message':{'content':[{'type':'tool_result','tool_use_id':'tool-' + str(len(old)),'content':'fixture output'}]}})
emit({'type':'result','is_error':False,'result':'Hello Claude'})
'''


class ClaudeChatTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        self.state = self.root / 'state'
        self.state.mkdir()
        self.project = self.root / 'project'
        self.project.mkdir()
        self.exe = self.root / 'claude-fixture'
        self.exe.write_text('#!' + sys.executable + '\n' + FAKE)
        self.exe.chmod(0o700)
        self.config = {'executable': str(self.exe), 'environment': {'FIXTURE_SECRET': 'never-save-me'}}
        self.bridge = Bridge(self.state, self.root, rpc_factory=FakeRPC)
        self.counter = 0

    def tearDown(self):
        self.bridge.claude.close()
        for runner in self.bridge.claude.turns.values():
            runner.closed.wait(5)
        self.bridge.store.db.close()
        self.temp.cleanup()

    def operation(self, action, **fields):
        self.counter += 1
        return self.bridge.dispatch(dict(action=action, operationId='claude-op-' + str(self.counter), **fields))

    def create(self):
        result = self.operation('create', cwd=str(self.project), agent='claude', mode='chat', agentConfiguration=self.config)
        self.assertTrue(result['ok'], result)
        return result['result']['id']

    def send(self, identifier, text):
        result = self.operation('send', sessionId=identifier, text=text, agentConfiguration=self.config)
        self.assertTrue(result['ok'], result)
        return result

    def wait(self, predicate):
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(.02)
        self.fail('Timed out waiting for fixture transport')

    def done(self, identifier):
        self.wait(lambda: self.bridge.claude.turns[identifier].closed.is_set())

    def test_streaming_reconciles_full_message_and_renders_tool_output(self):
        identifier = self.create()
        self.send(identifier, 'hello')
        self.done(identifier)
        session = self.bridge.snapshot(identifier)['selected']
        self.assertEqual(session['status'], 'completed')
        replies = [m for m in session['messages'] if m['kind'] == 'agentMessage']
        self.assertEqual([m['text'] for m in replies], ['Hello Claude'])
        self.assertIn('fixture output', session['messages'][-1]['text'])
        self.assertEqual(session['messages'][0]['status'], 'accepted')
        self.assertEqual(session['completedTurnId'], session['turnId'])
        self.assertFalse(self.bridge.rpc.calls)
        self.assertNotIn('never-save-me', json.dumps(self.bridge.store.load()))

    def test_resume_after_bridge_restart_preserves_same_session(self):
        identifier = self.create()
        self.send(identifier, 'first')
        self.done(identifier)
        remote = self.bridge.sessions[identifier]['remoteThreadId']
        self.bridge.store.db.close()
        self.bridge = Bridge(self.state, self.root, rpc_factory=FakeRPC)
        self.bridge.open_session({'sessionId': identifier})
        self.send(identifier, 'second')
        self.done(identifier)
        self.assertEqual((self.project / (remote + '.fixture-history')).read_text(), 'first\nsecond\n')
        self.assertEqual(len([m for m in self.bridge.sessions[identifier]['messages'] if m['kind'] == 'userMessage']), 2)

    def test_permission_allow_and_deny_are_explicit_control_responses(self):
        for decision in ['accept', 'decline', 'cancel']:
            identifier = self.create()
            self.send(identifier, 'approve')
            self.wait(lambda: self.bridge.sessions[identifier]['status'] == 'waiting')
            approval = self.bridge.sessions[identifier]['approvals'][0]
            result = self.operation('answer', sessionId=identifier, requestId=approval['id'], decision=decision)
            self.assertTrue(result['ok'], result)
            self.done(identifier)
            remote = self.bridge.sessions[identifier]['remoteThreadId']
            value = json.loads((self.project / (remote + '.fixture-approval')).read_text())
            self.assertEqual(value['behavior'], 'allow' if decision == 'accept' else 'deny')
            if decision == 'cancel':
                self.assertEqual(self.bridge.sessions[identifier]['status'], 'interrupted')
            self.assertFalse(self.bridge.sessions[identifier]['approvals'])
            self.assertFalse(self.operation('answer', sessionId=identifier, requestId=approval['id'], decision=decision)['ok'])

    def test_question_requires_all_answers_and_uses_claude_question_keys(self):
        identifier = self.create()
        self.send(identifier, 'question')
        self.wait(lambda: self.bridge.sessions[identifier]['status'] == 'waiting')
        approval = self.bridge.sessions[identifier]['approvals'][0]
        self.assertEqual(approval['method'], 'item/tool/requestUserInput')
        self.assertFalse(self.operation('answer', sessionId=identifier, requestId=approval['id'], answers={})['ok'])
        self.assertTrue(self.operation('answer', sessionId=identifier, requestId=approval['id'], answers={'0': 'main'})['ok'])
        self.done(identifier)
        remote = self.bridge.sessions[identifier]['remoteThreadId']
        value = json.loads((self.project / (remote + '.fixture-approval')).read_text())
        self.assertEqual(value['updatedInput']['answers'], {'Which branch?': 'main'})

    def test_stop_interrupts_only_the_selected_claude_turn(self):
        identifier = self.create()
        self.send(identifier, 'wait')
        self.wait(lambda: self.bridge.sessions[identifier]['status'] == 'inProgress')
        self.assertTrue(self.operation('stop', sessionId=identifier)['ok'])
        self.done(identifier)
        self.assertEqual(self.bridge.sessions[identifier]['status'], 'interrupted')

    def test_failures_are_visible_without_automatic_retry(self):
        for prompt in ['crash', 'malformed']:
            identifier = self.create()
            self.send(identifier, prompt)
            self.done(identifier)
            session = self.bridge.sessions[identifier]
            self.assertEqual(session['status'], 'failed')
            self.assertTrue(session['error'])
            self.assertFalse(session['approvals'])

    def test_send_retries_and_status_probe_do_not_repeat_process(self):
        identifier = self.create()
        request = dict(action='send', operationId='same-claude-message', sessionId=identifier, text='hello')
        first = self.bridge.dispatch(dict(request, agentConfiguration=self.config))
        self.done(identifier)
        self.assertEqual(first, self.bridge.dispatch(dict(request, agentConfiguration={'executable':'missing'})))
        self.assertEqual(self.bridge.store.operation_status(request)['state'], 'accepted')
        self.assertEqual(len(self.bridge.sessions[identifier]['messages']), 3)

    def test_codex_exit_and_writer_probe_never_touch_claude(self):
        identifier = self.create()
        self.send(identifier, 'wait')
        self.wait(lambda: self.bridge.sessions[identifier]['status'] == 'inProgress')
        with patch('bridge.thread_writer_occupied', side_effect=AssertionError('Codex lock queried')):
            self.bridge.snapshot(identifier)
        self.bridge.on_message({'method':'bridge/disconnected'})
        self.assertEqual(self.bridge.sessions[identifier]['status'], 'inProgress')
        self.bridge.claude.turns[identifier].stop()
        self.done(identifier)

    def test_history_paginates_without_codex_rpc(self):
        identifier = self.create()
        self.bridge.sessions[identifier]['messages'] = [dict(id=str(i), kind='agentMessage', text=str(i), status='completed') for i in range(85)]
        page = self.bridge.history_page({'sessionId':identifier})
        self.assertEqual(page['nextCursor'], '45')
        self.assertEqual(page['messages'][0]['id'], '45')
        page = self.bridge.history_page({'sessionId':identifier, 'cursor':page['nextCursor']})
        self.assertEqual(page['nextCursor'], '5')
        self.assertFalse(self.bridge.rpc.calls)

    def test_conflicting_protocol_and_permission_arguments_rejected(self):
        for argument in ['--resume=other', '--dangerously-skip-permissions', '--permission-mode bypassPermissions', '--output-format text']:
            with self.assertRaises(ValueError):
                configuration(dict(self.config, arguments=argument))

    def test_claude_chat_does_not_require_codex_and_rejects_invalid_attachments(self):
        from bridge import UnavailableCodex
        self.bridge.rpc = UnavailableCodex('not installed')
        identifier = self.create()
        result = self.operation('send', sessionId=identifier, text='hello', attachments=['missing'], agentConfiguration=self.config)
        self.assertFalse(result['ok'])
        self.assertFalse(self.bridge.sessions[identifier]['messages'])
        self.assertNotIn(identifier, self.bridge.claude.turns)
        self.send(identifier, 'hello')
        self.done(identifier)
        self.assertEqual(self.bridge.sessions[identifier]['status'], 'completed')

    def test_model_probe_returns_concrete_versions_without_starting_a_turn(self):
        identifier = self.create()
        result = self.bridge.dispatch({'action':'models', 'agent':'claude', 'sessionId':identifier, 'agentConfiguration':self.config})
        self.assertTrue(result['ok'], result)
        models = result['result']['models']
        self.assertEqual([m['model'] for m in models], ['fixture-model','fixture-fast'])
        self.assertEqual(models[0]['displayName'], 'Fixture Sonnet 1.0')
        self.assertEqual(models[0]['aliases'], ['default','sonnet'])
        self.assertEqual([e['reasoningEffort'] for e in models[0]['supportedReasoningEfforts']], ['low','high'])
        self.assertEqual(models[1]['supportedReasoningEfforts'], [])
        self.assertFalse(self.bridge.sessions[identifier]['messages'])
        self.assertFalse(list(self.project.glob('*.fixture-history')))
        self.assertFalse(self.bridge.rpc.calls)

    def test_selected_effort_is_validated_passed_to_cli_and_persisted(self):
        identifier = self.create()
        result = self.operation('send', sessionId=identifier, text='hello', model='fixture-model', effort='high', agentConfiguration=self.config)
        self.assertTrue(result['ok'], result)
        self.done(identifier)
        session = self.bridge.sessions[identifier]
        self.assertEqual(session['effort'], 'high')
        args = json.loads((self.project / (session['remoteThreadId'] + '.fixture-args')).read_text())
        self.assertEqual(args[args.index('--effort') + 1], 'high')
        for model,effort in [('fixture-fast','high'),('fixture-model','max'),('fixture-model','invalid')]:
            result = self.operation('send', sessionId=identifier, text='must not send', model=model, effort=effort, agentConfiguration=self.config)
            self.assertFalse(result['ok'])
        self.assertEqual(len([m for m in session['messages'] if m['kind']=='userMessage']),1)

    def test_model_catalog_cache_is_separated_by_project_and_configuration(self):
        identifier = self.create()
        request = {'sessionId':identifier,'agentConfiguration':self.config}
        self.bridge.claude.models(request)
        with patch('claude_runtime.ClaudeTurn', side_effect=AssertionError('Unexpected catalog process')):
            self.bridge.claude.models(request)
        self.assertEqual(len(self.bridge.claude.catalogs),1)
        self.bridge.claude.models(dict(request,agentConfiguration=dict(self.config,environment={'OTHER':'value'})))
        self.assertEqual(len(self.bridge.claude.catalogs),2)


if __name__ == '__main__':
    unittest.main()
