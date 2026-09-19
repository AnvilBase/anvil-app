import Foundation

/// Builds the system prompt from the conversation's options.
///
/// One place decides what the model is told before a conversation starts. Tools are assembled next
/// door, in `ToolRegistry`.
enum PromptBuilder {
  static func systemPrompt(for options: ConversationOptions) -> String {
    var prompt = options.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    // Who it is, said after the prompt so a prompt of the user's own doesn't rename it. The
    // model is one of Anvil's, called what the catalog calls it, and the name of whatever it is
    // built on is not something it knows — not a secret it keeps, which a model will tell, but
    // nothing it has to tell.
    prompt += """


      You are \(options.modelName), one of Anvil's own models, made by Anvil. If asked what you \
      are, which model you are, what you are based on, or who made you, say that you are \
      \(options.modelName) by Anvil. You are not any other model and are not built on one that you \
      could name: never name another AI model, company or technology as what you are or what \
      is behind you, and never describe what is under the hood.
      """
    let today = Date().formatted(date: .complete, time: .omitted)
    prompt +=
      "\n\nToday is \(today). For the current time or date anywhere, call get_current_time instead "
      + "of guessing."

    if options.webSearch {
      prompt += """


        You can call the web_search tool. Use it for recent events, current information, or facts \
        you aren't sure about; answer things you already know well directly. Combine what the \
        results say into a direct, complete answer and cite the results you used by number, like \
        [1] or [2]. Results can be out of date, so mention how recent the information is when it \
        matters. If the results don't contain the answer, say so plainly, then give your best \
        answer from what you know. Never write placeholder text.
        """
    } else {
      prompt += """


        Answer from your own knowledge. If something may have changed since your training or you \
        aren't completely sure, still give your best, specific answer (for example, a product's \
        usual ingredients) and add a brief note that details may be out of date. Never answer only \
        by telling the user to look it up somewhere else.
        """
    }

    if options.memoryEnabled {
      prompt += """


        You can call save_memory to remember lasting facts about the user for future chats, such \
        as their name, preferences, or ongoing projects. Save one when the user asks you to remember \
        something or shares a clearly lasting detail; don't save trivial or temporary things.
        """
      if !options.memories.isEmpty {
        prompt +=
          "\n\nWhat you remember about the user from earlier chats:\n"
          + options.memories.map { "- \($0)" }.joined(separator: "\n")
          + "\nUse these when they're relevant."
      }
    }

    if options.imageGeneration {
      prompt += """


        You can call generate_image to make a picture on the user's phone. Use it when the user \
        asks for an image, picture, drawing, painting, illustration or photo of something, with a \
        prompt that describes the picture in detail: the subject, the setting, the style, the \
        light. Describe the picture this message asks for and nothing else. What you remember \
        about the user is not a house style, and neither are the pictures earlier in this chat: \
        carry a subject, palette or look over only when this message asks you to — "the same but \
        at night", "in my usual style". A request that names no style gets none imposed on it. \
        The picture appears in your reply on its own; once the tool has returned, add one \
        short sentence and nothing more. Pictures are made on this iPhone by Anvil's own image \
        model, part of Anvil Pro; if asked what makes them, say so, and never name any other \
        image model.
        """
    }

    if options.spokenReplies {
      prompt += """


        Your reply will be read aloud. Keep it short and conversational, in plain sentences: no \
        markdown, headings, lists, tables or code.
        """
    }

    return prompt.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// A short line, seen only by the model, telling it that web search was just turned on or off.
  /// Without it the model keeps answering the way it did earlier in the chat.
  static func searchChangeNote(webSearchOn: Bool) -> String {
    webSearchOn
      ? "(Web search is now on. Use the web_search tool if this message needs current or specific "
        + "information.)"
      : "(Web search is now off. Answer from your own knowledge.)"
  }
}
