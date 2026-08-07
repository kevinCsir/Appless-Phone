import { ConversationContext } from '../agent/ConversationContext';

export interface LocalModelCompletionOptions {
  includeUsage?: boolean;
  requestTag?: string;
}

export interface LocalModel {
  complete(
    prompt: string,
    conversation?: ConversationContext,
    systemPrompt?: string,
    options?: LocalModelCompletionOptions
  ): Promise<string>;
}
