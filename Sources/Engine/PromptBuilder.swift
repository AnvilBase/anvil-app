import Foundation

/// Builds the system prompt from the conversation's options.
///
/// One place decides what the model is told before a conversation starts. Tools are assembled next
/// door, in `ToolRegistry`.
enum PromptBuilder {
  static func systemPrompt(for options: ConversationOptions) -> String {
    var prompt = options.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
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
        light. The picture appears in your reply on its own; once the tool has returned, add one \
        short sentence and nothing more.
        """
    } else {
      // The tool is there so that asking is answered; what it answers with is in its result.
      prompt += """


        When the user asks for an image, picture, drawing, painting, illustration or photo of \
        something, call generate_image with a short description of it. Pictures are part of Anvil \
        Pro; the tool's result says what the user needs, and your reply is that, in one short \
        sentence. Never describe or invent the picture yourself.
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
