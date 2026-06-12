import 'package:utopic/utopic.dart';
import 'package:test/test.dart';

void main() {
  test('ZenModels contains expected models', () {
    expect(ZenModels.all.length, greaterThan(0));
    expect(ZenModels.get('deepseek-v4-flash-free'), isNotNull);
    expect(ZenModels.get('claude-sonnet-4'), isNotNull);
  });

  test('ZenModels byId lookup', () {
    final model = ZenModels.get('deepseek-v4-flash-free');
    expect(model, isNotNull);
    expect(model!.provider, equals('deepseek'));
    expect(model.isFree, isTrue);
  });

  test('Message creation', () {
    final msg = Message(role: 'user', content: 'Hello');
    expect(msg.role, equals('user'));
    expect(msg.content, equals('Hello'));
    expect(msg.id, isNotEmpty);
  });

  test('Conversation management', () {
    final conv = Conversation();
    expect(conv.messages, isEmpty);

    conv.addMessage(Message(role: 'user', content: 'test'));
    expect(conv.messageCount, equals(1));
  });
}
