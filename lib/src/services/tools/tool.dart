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

  /// Describes this tool for the Responses API (OpenCode Zen).
  /// Produces the flat format that the Responses API expects:
  ///   {type, name, description, parameters}
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

  /// Describes this tool for the Chat Completions API (OpenRouter/OpenAI).
  /// Wraps the function details in a `function` field as required by
  /// the Chat Completions API format:
  ///   {type: "function", function: {name, description, parameters}}
  Map<String, dynamic> toChatJson() => {
    'type': 'function',
    'function': {
      'name': name,
      'description': description,
      'parameters': {
        'type': 'object',
        'properties': parameters,
        if (required.isNotEmpty) 'required': required,
      },
    },
  };
}
