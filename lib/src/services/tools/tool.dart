/// Base class for tools the AI can call.
abstract class Tool {
  String get name;
  String get description;

  /// JSON Schema for the tool's parameters.
  Map<String, dynamic> get parameters;

  /// Names of required parameters (subset of `parameters` keys).
  List<String> get required => [];

  /// Execute the tool with the given arguments.
  /// Returns the result as a string.
  Future<String> execute(Map<String, dynamic> args);

  /// Describes this tool in OpenAI-compatible format.
  Map<String, dynamic> toJson() => {
    'type': 'function',
    'name': name,
    'description': description,
    'parameters': {
      'type': 'object',
      'properties': parameters,
      if (required.isNotEmpty) 'required': required,
    },
  };
}
