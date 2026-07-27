#!/usr/bin/env node

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { createHash } from "crypto";

// Configuration
const QDRANT_URL = process.env.QDRANT_URL || "http://localhost:6334";
const QDRANT_API_KEY = process.env.QDRANT_API_KEY || "";
const OLLAMA_URL = process.env.OLLAMA_URL || "http://localhost:11434";

// Collection names
const COLLECTIONS = {
  // Tiered memory collections
  LONG_TERM: "claude_memories",
  SHORT_TERM: "short_term_memory",
  WORKING: "working_memory",
  // Hot/Warm/Cold tiering for auto-migration
  HOT: "memories_hot",      // Recent, frequently accessed (last 7 days)
  WARM: "memories_warm",    // Project-active, moderate access
  COLD: "memories_cold",    // Archived, rarely accessed (>90 days)
  // Specialized collections
  EPISODES: "episodes",
  LEARNINGS: "learnings",
  BENCHMARKS: "benchmarks",
  PROCEDURES: "procedures",     // NEW: Procedural memory
  TRAJECTORIES: "trajectories", // NEW: Successful execution traces
  LINKS: "memory_links",        // NEW: Memory relationships
  OBSIDIAN: "obsidian_docs",
};

// TTL constants (in milliseconds)
const TTL = {
  WORKING: 60 * 60 * 1000, // 1 hour default
  SHORT_TERM: 24 * 60 * 60 * 1000, // 24 hours
};

// Memory type enum
const MemoryType = z.enum(["preference", "fact", "context", "decision"]);

// Scratch operation enum
const ScratchOperation = z.enum(["create", "read", "update", "delete", "list", "clear"]);

// Episode status enum
const EpisodeStatus = z.enum(["active", "completed", "failed", "abandoned"]);

// Input schemas
const StoreMemorySchema = z.object({
  content: z.string().describe("The information to store in memory"),
  type: MemoryType.describe("Category of memory: preference, fact, context, or decision"),
  tags: z.array(z.string()).optional().describe("Tags for organizing the memory"),
  project: z.string().optional().default("global").describe("Project scope for the memory"),
});

const RecallMemorySchema = z.object({
  query: z.string().describe("Natural language search query to find relevant memories"),
  limit: z.number().optional().default(5).describe("Maximum number of memories to return (default: 5)"),
  include_short_term: z.boolean().optional().default(true).describe("Include short-term memories in search"),
});

const RagSearchSchema = z.object({
  query: z.string().describe("Natural language query to search the Obsidian vault documents"),
  limit: z.number().optional().default(5).describe("Maximum number of document chunks to return (default: 5)"),
  threshold: z.number().optional().default(0.4).describe("Minimum similarity score threshold (0-1, default: 0.4)"),
});

const ScratchSchema = z.object({
  operation: ScratchOperation.describe("Operation to perform: create, read, update, delete, list, or clear"),
  key: z.string().optional().describe("Named key for the scratch slot (required for create/read/update/delete)"),
  content: z.string().optional().describe("Content to store (required for create/update)"),
  ttl_minutes: z.number().optional().default(60).describe("Time-to-live in minutes (default: 60)"),
  task_id: z.string().optional().describe("Task ID to associate scratch with (for auto-cleanup)"),
});

const PromoteMemorySchema = z.object({
  memory_id: z.string().describe("ID of the memory to promote"),
  from_tier: z.enum(["working", "short_term"]).describe("Source tier"),
  to_tier: z.enum(["short_term", "long_term"]).describe("Destination tier"),
  type: MemoryType.optional().describe("Memory type (required when promoting to long_term)"),
});

const SummarizeMemorySchema = z.object({
  memory_ids: z.array(z.string()).describe("IDs of memories to summarize"),
  tier: z.enum(["working", "short_term", "long_term"]).describe("Which tier the memories are in"),
});

const EpisodeSchema = z.object({
  operation: z.enum(["start", "update", "complete", "search", "get"]).describe("Episode operation"),
  episode_id: z.string().optional().describe("Episode ID (required for update/complete/get)"),
  task: z.string().optional().describe("Task description (required for start)"),
  project: z.string().optional().describe("Project name"),
  agents_invoked: z.array(z.string()).optional().describe("List of agents used"),
  tools_used: z.array(z.string()).optional().describe("List of tools used"),
  files_modified: z.array(z.string()).optional().describe("List of files modified"),
  outcome: EpisodeStatus.optional().describe("Episode outcome"),
  learnings: z.array(z.string()).optional().describe("Learnings extracted from episode"),
  query: z.string().optional().describe("Search query (for search operation)"),
  limit: z.number().optional().default(5).describe("Number of results for search"),
});

const LearningSchema = z.object({
  operation: z.enum(["store", "search", "apply"]).describe("Learning operation"),
  content: z.string().optional().describe("Learning content (for store)"),
  domain: z.string().optional().describe("Domain/category of learning"),
  agent: z.string().optional().describe("Related agent name"),
  error_type: z.string().optional().describe("Type of error this learning addresses"),
  query: z.string().optional().describe("Search query (for search)"),
  limit: z.number().optional().default(5).describe("Number of results"),
});

const BenchmarkSchema = z.object({
  operation: z.enum(["record", "query", "compare"]).describe("Benchmark operation"),
  agent: z.string().optional().describe("Agent being benchmarked"),
  task_type: z.string().optional().describe("Type of task"),
  success: z.boolean().optional().describe("Whether task succeeded"),
  duration_ms: z.number().optional().describe("Execution duration in milliseconds"),
  tokens_used: z.number().optional().describe("Tokens consumed"),
  metadata: z.record(z.string(), z.unknown()).optional().describe("Additional metadata"),
  query: z.string().optional().describe("Query for searching benchmarks"),
  limit: z.number().optional().default(10).describe("Number of results"),
});

// NEW: Procedural Memory Schema
const ProcedureSchema = z.object({
  operation: z.enum(["capture", "search", "apply", "feedback", "list"]).describe("Procedure operation"),
  // For capture
  episode_id: z.string().optional().describe("Source episode ID"),
  name: z.string().optional().describe("Procedure name"),
  task_type: z.string().optional().describe("Type of task (database_migration, api_integration, etc.)"),
  domain: z.string().optional().describe("Domain (backend, frontend, devops, security)"),
  triggers: z.object({
    keywords: z.array(z.string()).optional(),
    file_patterns: z.array(z.string()).optional(),
    task_patterns: z.array(z.string()).optional(),
  }).optional().describe("Trigger conditions for this procedure"),
  steps: z.array(z.object({
    step: z.number(),
    action: z.string(),
    tools: z.array(z.string()).optional(),
    command_template: z.string().optional(),
    decision_points: z.array(z.object({
      condition: z.string(),
      action: z.string(),
    })).optional(),
  })).optional().describe("Procedure steps"),
  notes: z.string().optional().describe("Additional notes"),
  // For search/apply
  procedure_id: z.string().optional().describe("Procedure ID"),
  query: z.string().optional().describe("Search query"),
  context: z.record(z.string(), z.string()).optional().describe("Context variables for template substitution"),
  limit: z.number().optional().default(3).describe("Number of results"),
  // For feedback
  success: z.boolean().optional().describe("Whether procedure application succeeded"),
  improvement_notes: z.string().optional().describe("Notes on improvement"),
  refinements: z.array(z.string()).optional().describe("Suggested refinements"),
});

// NEW: Trajectory Schema (successful execution traces for few-shot learning)
const TrajectorySchema = z.object({
  operation: z.enum(["store", "recall", "feedback"]).describe("Trajectory operation"),
  // For store
  task_description: z.string().optional().describe("Description of the task"),
  task_type: z.string().optional().describe("Type of task"),
  execution_trace: z.array(z.object({
    step: z.number(),
    action: z.string(),
    tool: z.string().optional(),
    input_summary: z.string().optional(),
    output_summary: z.string().optional(),
    decision: z.string().optional(),
  })).optional().describe("Step-by-step execution trace"),
  key_decisions: z.array(z.string()).optional().describe("Important decisions made"),
  outcome: z.object({
    success: z.boolean(),
    metrics: z.record(z.string(), z.unknown()).optional(),
  }).optional().describe("Task outcome"),
  // For recall
  query: z.string().optional().describe("Search query for similar trajectories"),
  limit: z.number().optional().default(3).describe("Number of trajectories to return"),
  min_success_rate: z.number().optional().default(0.8).describe("Minimum success rate filter"),
  // For feedback
  trajectory_id: z.string().optional().describe("Trajectory ID"),
  was_helpful: z.boolean().optional().describe("Whether the trajectory was helpful"),
});

// NEW: Memory Link Schema (for knowledge graph relationships)
const MemoryLinkSchema = z.object({
  operation: z.enum(["link", "unlink", "traverse", "cluster", "prune"]).describe("Link operation"),
  // For link/unlink
  source_id: z.string().optional().describe("Source memory ID"),
  target_id: z.string().optional().describe("Target memory ID"),
  relationship: z.enum([
    "supports",      // Source supports/validates target
    "contradicts",   // Source contradicts target
    "extends",       // Source extends/elaborates target
    "supersedes",    // Source replaces/updates target
    "related",       // General relationship
    "prerequisite",  // Target requires source
    "derived_from",  // Source was derived from target
  ]).optional().describe("Type of relationship"),
  strength: z.number().optional().default(1.0).describe("Relationship strength 0-1"),
  // For traverse
  start_id: z.string().optional().describe("Starting memory ID for traversal"),
  max_depth: z.number().optional().default(2).describe("Maximum traversal depth"),
  relationship_filter: z.array(z.string()).optional().describe("Filter by relationship types"),
  // For cluster
  query: z.string().optional().describe("Query to find memories to cluster"),
  min_cluster_size: z.number().optional().default(3).describe("Minimum cluster size"),
  similarity_threshold: z.number().optional().default(0.85).describe("Similarity threshold for clustering"),
  action: z.enum(["identify", "merge", "summarize"]).optional().describe("What to do with clusters"),
  // For prune
  criteria: z.object({
    older_than_days: z.number().optional(),
    access_count_below: z.number().optional(),
    score_below: z.number().optional(),
    superseded: z.boolean().optional(),
  }).optional().describe("Pruning criteria"),
  dry_run: z.boolean().optional().default(true).describe("Preview without deleting"),
});

// Helper function to generate embedding via Ollama
async function generateEmbedding(text: string): Promise<number[] | null> {
  try {
    const response = await fetch(`${OLLAMA_URL}/api/embeddings`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ model: "nomic-embed-text", prompt: text }),
    });
    if (!response.ok) throw new Error(`Ollama error: ${response.status}`);
    const data = await response.json();
    return data.embedding;
  } catch (error) {
    console.error("Embedding error:", error);
    return null;
  }
}

// Helper function to generate UUID
function generateUUID(): string {
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
    const r = Math.random() * 16 | 0;
    const v = c === 'x' ? r : (r & 0x3 | 0x8);
    return v.toString(16);
  });
}

// Deterministic UUID from a string key (for scratch pad IDs)
function keyToUUID(key: string): string {
  const hash = createHash('sha256').update(key).digest('hex');
  return [
    hash.slice(0, 8),
    hash.slice(8, 12),
    '4' + hash.slice(13, 16),
    ((parseInt(hash[16], 16) & 0x3) | 0x8).toString(16) + hash.slice(17, 20),
    hash.slice(20, 32),
  ].join('-');
}

// Helper function to call Qdrant
async function qdrantRequest(
  method: string,
  path: string,
  body?: unknown
): Promise<unknown> {
  const response = await fetch(`${QDRANT_URL}${path}`, {
    method,
    headers: {
      "api-key": QDRANT_API_KEY,
      "Content-Type": "application/json",
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  if (!response.ok) {
    const errorText = await response.text();
    throw new Error(`Qdrant error: ${response.status} - ${errorText}`);
  }
  return response.json();
}

// Helper to store a point in Qdrant
async function storePoint(
  collection: string,
  id: string,
  vector: number[],
  payload: Record<string, unknown>
): Promise<void> {
  await qdrantRequest("PUT", `/collections/${collection}/points`, {
    points: [{ id, vector, payload }],
  });
}

// Helper to search Qdrant
async function searchPoints(
  collection: string,
  vector: number[],
  limit: number,
  threshold: number = 0.5,
  filter?: Record<string, unknown>
): Promise<unknown[]> {
  const body: Record<string, unknown> = {
    vector,
    limit,
    score_threshold: threshold,
    with_payload: true,
  };
  if (filter) body.filter = filter;

  const result = await qdrantRequest("POST", `/collections/${collection}/points/search`, body) as { result: unknown[] };
  return result.result || [];
}

// Helper to get a point by ID
async function getPoint(collection: string, id: string): Promise<unknown> {
  const result = await qdrantRequest("GET", `/collections/${collection}/points/${id}`) as { result: unknown };
  return result.result;
}

// Helper to delete points
async function deletePoints(collection: string, ids: string[]): Promise<void> {
  await qdrantRequest("POST", `/collections/${collection}/points/delete`, {
    points: ids,
  });
}

// Helper to scroll through points
async function scrollPoints(
  collection: string,
  filter?: Record<string, unknown>,
  limit: number = 100
): Promise<unknown[]> {
  const body: Record<string, unknown> = {
    limit,
    with_payload: true,
    with_vector: false,
  };
  if (filter) body.filter = filter;

  const result = await qdrantRequest("POST", `/collections/${collection}/points/scroll`, body) as { result: { points: unknown[] } };
  return result.result?.points || [];
}

// Create server
const server = new McpServer({
  name: "claude-memory",
  version: "2.0.0",
});

// ============================================
// LONG-TERM MEMORY TOOLS (Original)
// ============================================

server.tool(
  "memory_store",
  "Store information in persistent long-term memory with semantic embeddings. Use for preferences, facts, decisions, and context that should persist across sessions.",
  StoreMemorySchema.shape,
  async (args) => {
    try {
      const embedding = await generateEmbedding(args.content);
      if (!embedding) throw new Error("Failed to generate embedding");

      const id = generateUUID();
      const payload = {
        content: args.content,
        type: args.type,
        tags: args.tags || [],
        project: args.project || "global",
        created_at: new Date().toISOString(),
        tier: "long_term",
      };

      await storePoint(COLLECTIONS.LONG_TERM, id, embedding, payload);

      return {
        content: [{
          type: "text" as const,
          text: JSON.stringify({ success: true, id, message: "Memory stored in long-term storage" }, null, 2),
        }],
      };
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : "Unknown error";
      return {
        content: [{ type: "text" as const, text: `Error storing memory: ${errorMessage}` }],
        isError: true,
      };
    }
  }
);

server.tool(
  "memory_recall",
  "Search stored memories using semantic similarity. Searches both long-term and optionally short-term memories.",
  RecallMemorySchema.shape,
  async (args) => {
    try {
      const embedding = await generateEmbedding(args.query);
      if (!embedding) throw new Error("Failed to generate embedding");

      // Search long-term
      const longTermResults = await searchPoints(COLLECTIONS.LONG_TERM, embedding, args.limit || 5);

      // Optionally search short-term
      let shortTermResults: unknown[] = [];
      if (args.include_short_term !== false) {
        shortTermResults = await searchPoints(COLLECTIONS.SHORT_TERM, embedding, args.limit || 5);
      }

      // Merge and sort by score
      const allResults = [
        ...longTermResults.map((r: any) => ({ ...r, tier: "long_term" })),
        ...shortTermResults.map((r: any) => ({ ...r, tier: "short_term" })),
      ].sort((a: any, b: any) => b.score - a.score).slice(0, args.limit || 5);

      return {
        content: [{
          type: "text" as const,
          text: JSON.stringify({ success: true, memories: allResults }, null, 2),
        }],
      };
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : "Unknown error";
      return {
        content: [{ type: "text" as const, text: `Error recalling memories: ${errorMessage}` }],
        isError: true,
      };
    }
  }
);

server.tool(
  "rag_search",
  "Search the Obsidian vault using semantic similarity to find relevant document chunks.",
  RagSearchSchema.shape,
  async (args) => {
    try {
      const embedding = await generateEmbedding(args.query);
      if (!embedding) throw new Error("Failed to generate embedding");

      const results = await searchPoints(
        COLLECTIONS.OBSIDIAN,
        embedding,
        args.limit || 5,
        args.threshold || 0.4
      );

      return {
        content: [{
          type: "text" as const,
          text: JSON.stringify({ success: true, documents: results }, null, 2),
        }],
      };
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : "Unknown error";
      return {
        content: [{ type: "text" as const, text: `Error searching vault: ${errorMessage}` }],
        isError: true,
      };
    }
  }
);

// ============================================
// WORKING MEMORY (SCRATCH SPACE) TOOLS
// ============================================

server.tool(
  "memory_scratch",
  "Working memory scratch space for intermediate reasoning. Ephemeral storage that auto-expires. Use to offload context during complex reasoning.",
  ScratchSchema.shape,
  async (args) => {
    try {
      const { operation, key, content, ttl_minutes, task_id } = args;

      switch (operation) {
        case "create":
        case "update": {
          if (!key || !content) throw new Error("Key and content required for create/update");

          const embedding = await generateEmbedding(content);
          if (!embedding) throw new Error("Failed to generate embedding");

          const id = keyToUUID(`scratch_${key}`);
          const expires_at = new Date(Date.now() + (ttl_minutes || 60) * 60 * 1000).toISOString();

          await storePoint(COLLECTIONS.WORKING, id, embedding, {
            key,
            content,
            task_id: task_id || "default",
            created_at: new Date().toISOString(),
            expires_at,
            tier: "working",
          });

          return {
            content: [{
              type: "text" as const,
              text: JSON.stringify({ success: true, key, expires_at, message: `Scratch ${operation}d` }, null, 2),
            }],
          };
        }

        case "read": {
          if (!key) throw new Error("Key required for read");

          try {
            const point = await getPoint(COLLECTIONS.WORKING, keyToUUID(`scratch_${key}`)) as any;
            if (!point) throw new Error("Scratch not found");

            // Check expiration
            if (point.payload?.expires_at && new Date(point.payload.expires_at) < new Date()) {
              await deletePoints(COLLECTIONS.WORKING, [keyToUUID(`scratch_${key}`)]);
              throw new Error("Scratch has expired");
            }

            return {
              content: [{
                type: "text" as const,
                text: JSON.stringify({ success: true, key, content: point.payload?.content, expires_at: point.payload?.expires_at }, null, 2),
              }],
            };
          } catch {
            return {
              content: [{
                type: "text" as const,
                text: JSON.stringify({ success: false, key, message: "Scratch not found or expired" }, null, 2),
              }],
            };
          }
        }

        case "delete": {
          if (!key) throw new Error("Key required for delete");
          await deletePoints(COLLECTIONS.WORKING, [keyToUUID(`scratch_${key}`)]);
          return {
            content: [{
              type: "text" as const,
              text: JSON.stringify({ success: true, key, message: "Scratch deleted" }, null, 2),
            }],
          };
        }

        case "list": {
          const filter = task_id ? { must: [{ key: "task_id", match: { value: task_id } }] } : undefined;
          const points = await scrollPoints(COLLECTIONS.WORKING, filter, 100);
          const scratches = points.map((p: any) => ({
            key: p.payload?.key,
            task_id: p.payload?.task_id,
            expires_at: p.payload?.expires_at,
            preview: p.payload?.content?.substring(0, 100) + "...",
          }));
          return {
            content: [{
              type: "text" as const,
              text: JSON.stringify({ success: true, scratches }, null, 2),
            }],
          };
        }

        case "clear": {
          const filter = task_id
            ? { must: [{ key: "task_id", match: { value: task_id } }] }
            : undefined;
          const points = await scrollPoints(COLLECTIONS.WORKING, filter, 1000);
          const ids = points.map((p: any) => p.id);
          if (ids.length > 0) {
            await deletePoints(COLLECTIONS.WORKING, ids);
          }
          return {
            content: [{
              type: "text" as const,
              text: JSON.stringify({ success: true, cleared: ids.length, message: "Scratch space cleared" }, null, 2),
            }],
          };
        }

        default:
          throw new Error(`Unknown operation: ${operation}`);
      }
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : "Unknown error";
      return {
        content: [{ type: "text" as const, text: `Error in scratch operation: ${errorMessage}` }],
        isError: true,
      };
    }
  }
);

// ============================================
// MEMORY TIER MANAGEMENT
// ============================================

server.tool(
  "memory_promote",
  "Promote memory from one tier to another (working -> short_term -> long_term). Use to preserve important working memory before it expires.",
  PromoteMemorySchema.shape,
  async (args) => {
    try {
      const { memory_id, from_tier, to_tier, type } = args;

      // Determine source collection
      const sourceCollection = from_tier === "working" ? COLLECTIONS.WORKING : COLLECTIONS.SHORT_TERM;
      const destCollection = to_tier === "short_term" ? COLLECTIONS.SHORT_TERM : COLLECTIONS.LONG_TERM;

      // Get source point
      const point = await getPoint(sourceCollection, memory_id) as any;
      if (!point) throw new Error("Memory not found in source tier");

      // Generate new embedding if needed (content might have been modified)
      const content = point.payload?.content;
      if (!content) throw new Error("Memory has no content");

      const embedding = await generateEmbedding(content);
      if (!embedding) throw new Error("Failed to generate embedding");

      // Create new payload for destination
      const newPayload: Record<string, unknown> = {
        ...point.payload,
        tier: to_tier,
        promoted_from: from_tier,
        promoted_at: new Date().toISOString(),
      };

      // Add required fields for long-term
      if (to_tier === "long_term") {
        if (!type) throw new Error("Type required when promoting to long_term");
        newPayload.type = type;
        delete newPayload.expires_at;
      } else {
        // Set new expiration for short-term
        newPayload.expires_at = new Date(Date.now() + TTL.SHORT_TERM).toISOString();
      }

      // Store in destination
      const newId = generateUUID();
      await storePoint(destCollection, newId, embedding, newPayload);

      // Delete from source
      await deletePoints(sourceCollection, [memory_id]);

      return {
        content: [{
          type: "text" as const,
          text: JSON.stringify({
            success: true,
            old_id: memory_id,
            new_id: newId,
            from_tier,
            to_tier,
            message: "Memory promoted successfully",
          }, null, 2),
        }],
      };
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : "Unknown error";
      return {
        content: [{ type: "text" as const, text: `Error promoting memory: ${errorMessage}` }],
        isError: true,
      };
    }
  }
);

server.tool(
  "memory_summarize",
  "Summarize multiple memories into a consolidated memory. Use to compress verbose memories while preserving key information.",
  SummarizeMemorySchema.shape,
  async (args) => {
    try {
      const { memory_ids, tier } = args;

      // Determine collection
      const collection = tier === "working" ? COLLECTIONS.WORKING
        : tier === "short_term" ? COLLECTIONS.SHORT_TERM
        : COLLECTIONS.LONG_TERM;

      // Fetch all memories
      const memories: string[] = [];
      for (const id of memory_ids) {
        try {
          const point = await getPoint(collection, id) as any;
          if (point?.payload?.content) {
            memories.push(point.payload.content);
          }
        } catch {
          // Skip missing memories
        }
      }

      if (memories.length === 0) {
        throw new Error("No memories found to summarize");
      }

      // Create summary (simple concatenation with marker - in production, use LLM)
      const summary = `[SUMMARIZED from ${memories.length} memories]\n\n` +
        memories.map((m, i) => `[${i + 1}] ${m}`).join("\n\n---\n\n");

      // Store summary
      const embedding = await generateEmbedding(summary);
      if (!embedding) throw new Error("Failed to generate embedding");

      const newId = generateUUID();
      await storePoint(collection, newId, embedding, {
        content: summary,
        type: "context",
        summarized_from: memory_ids,
        created_at: new Date().toISOString(),
        tier,
        is_summary: true,
      });

      // Optionally delete originals (commented out for safety)
      // await deletePoints(collection, memory_ids);

      return {
        content: [{
          type: "text" as const,
          text: JSON.stringify({
            success: true,
            summary_id: newId,
            source_count: memories.length,
            message: "Memories summarized (originals preserved)",
          }, null, 2),
        }],
      };
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : "Unknown error";
      return {
        content: [{ type: "text" as const, text: `Error summarizing memories: ${errorMessage}` }],
        isError: true,
      };
    }
  }
);

// ============================================
// EPISODE MANAGEMENT
// ============================================

server.tool(
  "episode",
  "Manage task episodes for learning. Record task executions with context, actions, and outcomes for future reference.",
  EpisodeSchema.shape,
  async (args) => {
    try {
      const { operation } = args;

      switch (operation) {
        case "start": {
          if (!args.task) throw new Error("Task description required");

          const embedding = await generateEmbedding(args.task);
          if (!embedding) throw new Error("Failed to generate embedding");

          const id = generateUUID();
          await storePoint(COLLECTIONS.EPISODES, id, embedding, {
            task: args.task,
            project: args.project || "global",
            status: "active",
            started_at: new Date().toISOString(),
            agents_invoked: [],
            tools_used: [],
            files_modified: [],
            learnings: [],
          });

          return {
            content: [{
              type: "text" as const,
              text: JSON.stringify({ success: true, episode_id: id, status: "active" }, null, 2),
            }],
          };
        }

        case "update": {
          if (!args.episode_id) throw new Error("Episode ID required");

          const point = await getPoint(COLLECTIONS.EPISODES, args.episode_id) as any;
          if (!point) throw new Error("Episode not found");

          const payload = point.payload || {};

          // Merge arrays
          if (args.agents_invoked) {
            payload.agents_invoked = [...new Set([...(payload.agents_invoked || []), ...args.agents_invoked])];
          }
          if (args.tools_used) {
            payload.tools_used = [...new Set([...(payload.tools_used || []), ...args.tools_used])];
          }
          if (args.files_modified) {
            payload.files_modified = [...new Set([...(payload.files_modified || []), ...args.files_modified])];
          }
          if (args.learnings) {
            payload.learnings = [...(payload.learnings || []), ...args.learnings];
          }

          payload.updated_at = new Date().toISOString();

          // Re-embed with updated context
          const contextText = `${payload.task} ${payload.agents_invoked?.join(" ")} ${payload.tools_used?.join(" ")}`;
          const embedding = await generateEmbedding(contextText);
          if (!embedding) throw new Error("Failed to generate embedding");

          await storePoint(COLLECTIONS.EPISODES, args.episode_id, embedding, payload);

          return {
            content: [{
              type: "text" as const,
              text: JSON.stringify({ success: true, episode_id: args.episode_id, message: "Episode updated" }, null, 2),
            }],
          };
        }

        case "complete": {
          if (!args.episode_id) throw new Error("Episode ID required");

          const point = await getPoint(COLLECTIONS.EPISODES, args.episode_id) as any;
          if (!point) throw new Error("Episode not found");

          const payload = point.payload || {};
          payload.status = args.outcome || "completed";
          payload.completed_at = new Date().toISOString();
          payload.duration_ms = new Date().getTime() - new Date(payload.started_at).getTime();

          if (args.learnings) {
            payload.learnings = [...(payload.learnings || []), ...args.learnings];
          }

          const contextText = `${payload.task} ${payload.status} ${payload.learnings?.join(" ")}`;
          const embedding = await generateEmbedding(contextText);
          if (!embedding) throw new Error("Failed to generate embedding");

          await storePoint(COLLECTIONS.EPISODES, args.episode_id, embedding, payload);

          return {
            content: [{
              type: "text" as const,
              text: JSON.stringify({
                success: true,
                episode_id: args.episode_id,
                status: payload.status,
                duration_ms: payload.duration_ms,
              }, null, 2),
            }],
          };
        }

        case "search": {
          if (!args.query) throw new Error("Query required for search");

          const embedding = await generateEmbedding(args.query);
          if (!embedding) throw new Error("Failed to generate embedding");

          const results = await searchPoints(COLLECTIONS.EPISODES, embedding, args.limit || 5, 0.3);

          return {
            content: [{
              type: "text" as const,
              text: JSON.stringify({ success: true, episodes: results }, null, 2),
            }],
          };
        }

        case "get": {
          if (!args.episode_id) throw new Error("Episode ID required");

          const point = await getPoint(COLLECTIONS.EPISODES, args.episode_id) as any;
          if (!point) throw new Error("Episode not found");

          return {
            content: [{
              type: "text" as const,
              text: JSON.stringify({ success: true, episode: point.payload }, null, 2),
            }],
          };
        }

        default:
          throw new Error(`Unknown operation: ${operation}`);
      }
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : "Unknown error";
      return {
        content: [{ type: "text" as const, text: `Error in episode operation: ${errorMessage}` }],
        isError: true,
      };
    }
  }
);

// ============================================
// LEARNING MANAGEMENT
// ============================================

server.tool(
  "learning",
  "Manage learnings extracted from task executions. Store, search, and apply learnings to improve future performance.",
  LearningSchema.shape,
  async (args) => {
    try {
      const { operation } = args;

      switch (operation) {
        case "store": {
          if (!args.content) throw new Error("Content required");

          const embedding = await generateEmbedding(args.content);
          if (!embedding) throw new Error("Failed to generate embedding");

          const id = generateUUID();
          await storePoint(COLLECTIONS.LEARNINGS, id, embedding, {
            content: args.content,
            domain: args.domain || "general",
            agent: args.agent,
            error_type: args.error_type,
            created_at: new Date().toISOString(),
            applied_count: 0,
            effectiveness_score: null,
          });

          return {
            content: [{
              type: "text" as const,
              text: JSON.stringify({ success: true, learning_id: id }, null, 2),
            }],
          };
        }

        case "search": {
          if (!args.query) throw new Error("Query required");

          const embedding = await generateEmbedding(args.query);
          if (!embedding) throw new Error("Failed to generate embedding");

          // Build filter
          const must: Record<string, unknown>[] = [];
          if (args.domain) must.push({ key: "domain", match: { value: args.domain } });
          if (args.agent) must.push({ key: "agent", match: { value: args.agent } });
          if (args.error_type) must.push({ key: "error_type", match: { value: args.error_type } });

          const filter = must.length > 0 ? { must } : undefined;
          const results = await searchPoints(COLLECTIONS.LEARNINGS, embedding, args.limit || 5, 0.3, filter);

          return {
            content: [{
              type: "text" as const,
              text: JSON.stringify({ success: true, learnings: results }, null, 2),
            }],
          };
        }

        case "apply": {
          // Search for relevant learnings and return them formatted for injection
          if (!args.query) throw new Error("Query required");

          const embedding = await generateEmbedding(args.query);
          if (!embedding) throw new Error("Failed to generate embedding");

          const filter = args.agent ? { must: [{ key: "agent", match: { value: args.agent } }] } : undefined;
          const results = await searchPoints(COLLECTIONS.LEARNINGS, embedding, args.limit || 3, 0.4, filter) as any[];

          if (results.length === 0) {
            return {
              content: [{
                type: "text" as const,
                text: JSON.stringify({ success: true, learnings: [], message: "No relevant learnings found" }, null, 2),
              }],
            };
          }

          // Format for prompt injection
          const formatted = results.map((r: any, i: number) =>
            `[Learning ${i + 1}] ${r.payload?.content}`
          ).join("\n\n");

          return {
            content: [{
              type: "text" as const,
              text: JSON.stringify({
                success: true,
                count: results.length,
                formatted_learnings: formatted,
                raw_learnings: results,
              }, null, 2),
            }],
          };
        }

        default:
          throw new Error(`Unknown operation: ${operation}`);
      }
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : "Unknown error";
      return {
        content: [{ type: "text" as const, text: `Error in learning operation: ${errorMessage}` }],
        isError: true,
      };
    }
  }
);

// ============================================
// BENCHMARKING
// ============================================

server.tool(
  "benchmark",
  "Record and query performance benchmarks. Track agent success rates, execution times, and token usage.",
  BenchmarkSchema.shape,
  async (args) => {
    try {
      const { operation } = args;

      switch (operation) {
        case "record": {
          if (!args.agent || !args.task_type || args.success === undefined) {
            throw new Error("Agent, task_type, and success required");
          }

          const text = `${args.agent} ${args.task_type} ${args.success ? "success" : "failure"}`;
          const embedding = await generateEmbedding(text);
          if (!embedding) throw new Error("Failed to generate embedding");

          const id = generateUUID();
          await storePoint(COLLECTIONS.BENCHMARKS, id, embedding, {
            agent: args.agent,
            task_type: args.task_type,
            success: args.success,
            duration_ms: args.duration_ms,
            tokens_used: args.tokens_used,
            metadata: args.metadata || {},
            recorded_at: new Date().toISOString(),
          });

          return {
            content: [{
              type: "text" as const,
              text: JSON.stringify({ success: true, benchmark_id: id }, null, 2),
            }],
          };
        }

        case "query": {
          // Get recent benchmarks, optionally filtered
          const filter: Record<string, unknown>[] = [];
          if (args.agent) filter.push({ key: "agent", match: { value: args.agent } });
          if (args.task_type) filter.push({ key: "task_type", match: { value: args.task_type } });

          const filterObj = filter.length > 0 ? { must: filter } : undefined;
          const points = await scrollPoints(COLLECTIONS.BENCHMARKS, filterObj, args.limit || 10);

          // Calculate stats
          const successes = points.filter((p: any) => p.payload?.success).length;
          const total = points.length;
          const avgDuration = points.reduce((sum: number, p: any) => sum + (p.payload?.duration_ms || 0), 0) / (total || 1);

          return {
            content: [{
              type: "text" as const,
              text: JSON.stringify({
                success: true,
                stats: {
                  total,
                  successes,
                  failures: total - successes,
                  success_rate: total > 0 ? (successes / total * 100).toFixed(1) + "%" : "N/A",
                  avg_duration_ms: Math.round(avgDuration),
                },
                benchmarks: points.map((p: any) => p.payload),
              }, null, 2),
            }],
          };
        }

        case "compare": {
          // Compare performance across agents or task types
          const points = await scrollPoints(COLLECTIONS.BENCHMARKS, undefined, 1000);

          // Group by agent
          const byAgent: Record<string, { success: number; total: number; duration: number }> = {};
          for (const p of points as any[]) {
            const agent = p.payload?.agent || "unknown";
            if (!byAgent[agent]) byAgent[agent] = { success: 0, total: 0, duration: 0 };
            byAgent[agent].total++;
            if (p.payload?.success) byAgent[agent].success++;
            byAgent[agent].duration += p.payload?.duration_ms || 0;
          }

          const comparison = Object.entries(byAgent).map(([agent, stats]) => ({
            agent,
            total: stats.total,
            success_rate: ((stats.success / stats.total) * 100).toFixed(1) + "%",
            avg_duration_ms: Math.round(stats.duration / stats.total),
          })).sort((a, b) => parseFloat(b.success_rate) - parseFloat(a.success_rate));

          return {
            content: [{
              type: "text" as const,
              text: JSON.stringify({ success: true, comparison }, null, 2),
            }],
          };
        }

        default:
          throw new Error(`Unknown operation: ${operation}`);
      }
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : "Unknown error";
      return {
        content: [{ type: "text" as const, text: `Error in benchmark operation: ${errorMessage}` }],
        isError: true,
      };
    }
  }
);

// ============================================
// PROCEDURAL MEMORY
// ============================================

server.tool(
  "procedure",
  "Manage procedural memory - reusable step-by-step patterns extracted from successful task executions. Capture, search, apply, and improve procedures.",
  ProcedureSchema.shape,
  async (args) => {
    try {
      const { operation } = args;

      switch (operation) {
        case "capture": {
          if (!args.name || !args.steps) throw new Error("Name and steps required");

          const searchText = `${args.name} ${args.task_type || ""} ${args.domain || ""} ${args.triggers?.keywords?.join(" ") || ""}`;
          const embedding = await generateEmbedding(searchText);
          if (!embedding) throw new Error("Failed to generate embedding");

          const id = generateUUID();
          await storePoint(COLLECTIONS.PROCEDURES, id, embedding, {
            name: args.name,
            task_type: args.task_type,
            domain: args.domain,
            triggers: args.triggers || {},
            steps: args.steps,
            notes: args.notes,
            source_episode: args.episode_id,
            created_at: new Date().toISOString(),
            version: 1,
            times_used: 0,
            success_count: 0,
            failure_count: 0,
            status: "new", // new -> proven -> trusted
          });

          return {
            content: [{
              type: "text" as const,
              text: JSON.stringify({ success: true, procedure_id: id, name: args.name }, null, 2),
            }],
          };
        }

        case "search": {
          if (!args.query) throw new Error("Query required");

          const embedding = await generateEmbedding(args.query);
          if (!embedding) throw new Error("Failed to generate embedding");

          const filter: Record<string, unknown>[] = [];
          if (args.task_type) filter.push({ key: "task_type", match: { value: args.task_type } });
          if (args.domain) filter.push({ key: "domain", match: { value: args.domain } });

          const filterObj = filter.length > 0 ? { must: filter } : undefined;
          const results = await searchPoints(COLLECTIONS.PROCEDURES, embedding, args.limit || 3, 0.5, filterObj);

          return {
            content: [{
              type: "text" as const,
              text: JSON.stringify({ success: true, procedures: results }, null, 2),
            }],
          };
        }

        case "apply": {
          if (!args.procedure_id) throw new Error("Procedure ID required");

          const point = await getPoint(COLLECTIONS.PROCEDURES, args.procedure_id) as any;
          if (!point) throw new Error("Procedure not found");

          const procedure = point.payload;

          // Format as few-shot example
          let formatted = `## PROCEDURAL KNOWLEDGE: ${procedure.name}\n\n`;
          formatted += `**Task Type:** ${procedure.task_type || "general"}\n`;
          formatted += `**Success Rate:** ${procedure.times_used > 0 ? ((procedure.success_count / procedure.times_used) * 100).toFixed(0) : "N/A"}%\n`;
          formatted += `**Times Used:** ${procedure.times_used}\n\n`;
          formatted += `### Steps:\n\n`;

          for (const step of procedure.steps || []) {
            formatted += `**Step ${step.step}: ${step.action}**\n`;
            if (step.tools) formatted += `- Tools: ${step.tools.join(", ")}\n`;
            if (step.command_template) {
              let template = step.command_template;
              // Substitute context variables
              if (args.context) {
                for (const [key, value] of Object.entries(args.context)) {
                  template = template.replace(new RegExp(`\\$${key}`, "g"), value);
                }
              }
              formatted += `- Command: \`${template}\`\n`;
            }
            if (step.decision_points) {
              for (const dp of step.decision_points) {
                formatted += `- ⚠️ If ${dp.condition}: ${dp.action}\n`;
              }
            }
            formatted += "\n";
          }

          if (procedure.notes) {
            formatted += `### Notes:\n${procedure.notes}\n`;
          }

          // Update usage count
          procedure.times_used = (procedure.times_used || 0) + 1;
          procedure.last_used = new Date().toISOString();

          const embedding = await generateEmbedding(`${procedure.name} ${procedure.task_type}`);
          if (embedding) {
            await storePoint(COLLECTIONS.PROCEDURES, args.procedure_id, embedding, procedure);
          }

          return {
            content: [{
              type: "text" as const,
              text: JSON.stringify({
                success: true,
                formatted_procedure: formatted,
                raw_procedure: procedure,
              }, null, 2),
            }],
          };
        }

        case "feedback": {
          if (!args.procedure_id) throw new Error("Procedure ID required");

          const point = await getPoint(COLLECTIONS.PROCEDURES, args.procedure_id) as any;
          if (!point) throw new Error("Procedure not found");

          const procedure = point.payload;

          if (args.success !== undefined) {
            if (args.success) {
              procedure.success_count = (procedure.success_count || 0) + 1;
            } else {
              procedure.failure_count = (procedure.failure_count || 0) + 1;
            }
          }

          if (args.improvement_notes) {
            procedure.feedback_history = procedure.feedback_history || [];
            procedure.feedback_history.push({
              timestamp: new Date().toISOString(),
              notes: args.improvement_notes,
              refinements: args.refinements,
            });
          }

          // Update status based on metrics
          const totalUses = procedure.times_used || 0;
          const successRate = totalUses > 0 ? procedure.success_count / totalUses : 0;

          if (totalUses >= 10 && successRate >= 0.85) {
            procedure.status = "trusted";
          } else if (totalUses >= 3 && successRate >= 0.7) {
            procedure.status = "proven";
          }

          procedure.updated_at = new Date().toISOString();

          const embedding = await generateEmbedding(`${procedure.name} ${procedure.task_type}`);
          if (embedding) {
            await storePoint(COLLECTIONS.PROCEDURES, args.procedure_id, embedding, procedure);
          }

          return {
            content: [{
              type: "text" as const,
              text: JSON.stringify({
                success: true,
                procedure_id: args.procedure_id,
                status: procedure.status,
                success_rate: totalUses > 0 ? (successRate * 100).toFixed(0) + "%" : "N/A",
              }, null, 2),
            }],
          };
        }

        case "list": {
          const filter: Record<string, unknown>[] = [];
          if (args.task_type) filter.push({ key: "task_type", match: { value: args.task_type } });
          if (args.domain) filter.push({ key: "domain", match: { value: args.domain } });

          const filterObj = filter.length > 0 ? { must: filter } : undefined;
          const points = await scrollPoints(COLLECTIONS.PROCEDURES, filterObj, args.limit || 20);

          const procedures = points.map((p: any) => ({
            id: p.id,
            name: p.payload?.name,
            task_type: p.payload?.task_type,
            domain: p.payload?.domain,
            status: p.payload?.status,
            times_used: p.payload?.times_used,
            success_rate: p.payload?.times_used > 0
              ? ((p.payload?.success_count / p.payload?.times_used) * 100).toFixed(0) + "%"
              : "N/A",
          }));

          return {
            content: [{
              type: "text" as const,
              text: JSON.stringify({ success: true, procedures }, null, 2),
            }],
          };
        }

        default:
          throw new Error(`Unknown operation: ${operation}`);
      }
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : "Unknown error";
      return {
        content: [{ type: "text" as const, text: `Error in procedure operation: ${errorMessage}` }],
        isError: true,
      };
    }
  }
);

// ============================================
// TRAJECTORY MEMORY (Few-Shot Learning)
// ============================================

server.tool(
  "trajectory",
  "Store and recall successful execution trajectories for few-shot learning. When similar tasks are attempted, relevant past successes are provided as examples.",
  TrajectorySchema.shape,
  async (args) => {
    try {
      const { operation } = args;

      switch (operation) {
        case "store": {
          if (!args.task_description || !args.execution_trace || !args.outcome) {
            throw new Error("task_description, execution_trace, and outcome required");
          }

          // Only store successful trajectories
          if (!args.outcome.success) {
            return {
              content: [{
                type: "text" as const,
                text: JSON.stringify({
                  success: false,
                  message: "Only successful trajectories are stored for few-shot learning",
                }, null, 2),
              }],
            };
          }

          const searchText = `${args.task_description} ${args.task_type || ""} ${args.key_decisions?.join(" ") || ""}`;
          const embedding = await generateEmbedding(searchText);
          if (!embedding) throw new Error("Failed to generate embedding");

          const id = generateUUID();
          await storePoint(COLLECTIONS.TRAJECTORIES, id, embedding, {
            task_description: args.task_description,
            task_type: args.task_type,
            execution_trace: args.execution_trace,
            key_decisions: args.key_decisions || [],
            outcome: args.outcome,
            created_at: new Date().toISOString(),
            times_recalled: 0,
            helpfulness_score: null,
            helpfulness_count: 0,
          });

          return {
            content: [{
              type: "text" as const,
              text: JSON.stringify({ success: true, trajectory_id: id }, null, 2),
            }],
          };
        }

        case "recall": {
          if (!args.query) throw new Error("Query required");

          const embedding = await generateEmbedding(args.query);
          if (!embedding) throw new Error("Failed to generate embedding");

          const results = await searchPoints(
            COLLECTIONS.TRAJECTORIES,
            embedding,
            args.limit || 3,
            0.6
          ) as any[];

          if (results.length === 0) {
            return {
              content: [{
                type: "text" as const,
                text: JSON.stringify({
                  success: true,
                  trajectories: [],
                  message: "No similar successful trajectories found",
                }, null, 2),
              }],
            };
          }

          // Format as few-shot examples
          let formatted = "## RELEVANT PAST SUCCESSES (Few-Shot Examples)\n\n";

          for (let i = 0; i < results.length; i++) {
            const traj = results[i].payload;
            formatted += `### Example ${i + 1}: ${traj.task_description}\n\n`;
            formatted += `**Task Type:** ${traj.task_type || "general"}\n`;
            formatted += `**Helpfulness:** ${traj.helpfulness_score ? (traj.helpfulness_score * 100).toFixed(0) + "%" : "Not rated"}\n\n`;
            formatted += `**Execution Steps:**\n`;

            for (const step of traj.execution_trace || []) {
              formatted += `${step.step}. ${step.action}`;
              if (step.tool) formatted += ` [${step.tool}]`;
              if (step.decision) formatted += `\n   → Decision: ${step.decision}`;
              formatted += "\n";
            }

            if (traj.key_decisions?.length) {
              formatted += `\n**Key Decisions:**\n`;
              for (const decision of traj.key_decisions) {
                formatted += `- ${decision}\n`;
              }
            }

            formatted += "\n---\n\n";

            // Update recall count
            traj.times_recalled = (traj.times_recalled || 0) + 1;
            traj.last_recalled = new Date().toISOString();

            const trajEmbedding = await generateEmbedding(`${traj.task_description} ${traj.task_type}`);
            if (trajEmbedding) {
              await storePoint(COLLECTIONS.TRAJECTORIES, results[i].id, trajEmbedding, traj);
            }
          }

          return {
            content: [{
              type: "text" as const,
              text: JSON.stringify({
                success: true,
                count: results.length,
                formatted_examples: formatted,
                trajectories: results,
              }, null, 2),
            }],
          };
        }

        case "feedback": {
          if (!args.trajectory_id || args.was_helpful === undefined) {
            throw new Error("trajectory_id and was_helpful required");
          }

          const point = await getPoint(COLLECTIONS.TRAJECTORIES, args.trajectory_id) as any;
          if (!point) throw new Error("Trajectory not found");

          const traj = point.payload;

          // Update helpfulness score (running average)
          const oldCount = traj.helpfulness_count || 0;
          const oldScore = traj.helpfulness_score || 0;
          const newValue = args.was_helpful ? 1 : 0;

          traj.helpfulness_count = oldCount + 1;
          traj.helpfulness_score = (oldScore * oldCount + newValue) / traj.helpfulness_count;
          traj.updated_at = new Date().toISOString();

          const embedding = await generateEmbedding(`${traj.task_description} ${traj.task_type}`);
          if (embedding) {
            await storePoint(COLLECTIONS.TRAJECTORIES, args.trajectory_id, embedding, traj);
          }

          return {
            content: [{
              type: "text" as const,
              text: JSON.stringify({
                success: true,
                trajectory_id: args.trajectory_id,
                helpfulness_score: (traj.helpfulness_score * 100).toFixed(0) + "%",
                feedback_count: traj.helpfulness_count,
              }, null, 2),
            }],
          };
        }

        default:
          throw new Error(`Unknown operation: ${operation}`);
      }
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : "Unknown error";
      return {
        content: [{ type: "text" as const, text: `Error in trajectory operation: ${errorMessage}` }],
        isError: true,
      };
    }
  }
);

// ============================================
// MEMORY SELF-ORGANIZATION (Links, Clusters, Pruning)
// ============================================

server.tool(
  "memory_organize",
  "Self-organizing memory operations: link memories together, find clusters, prune stale memories. Enables knowledge graph relationships and intelligent memory management.",
  MemoryLinkSchema.shape,
  async (args) => {
    try {
      const { operation } = args;

      switch (operation) {
        case "link": {
          if (!args.source_id || !args.target_id || !args.relationship) {
            throw new Error("source_id, target_id, and relationship required");
          }

          const linkText = `${args.source_id} ${args.relationship} ${args.target_id}`;
          const embedding = await generateEmbedding(linkText);
          if (!embedding) throw new Error("Failed to generate embedding");

          const id = `link_${args.source_id}_${args.target_id}`;
          await storePoint(COLLECTIONS.LINKS, id, embedding, {
            source_id: args.source_id,
            target_id: args.target_id,
            relationship: args.relationship,
            strength: args.strength || 1.0,
            created_at: new Date().toISOString(),
          });

          return {
            content: [{
              type: "text" as const,
              text: JSON.stringify({
                success: true,
                link_id: id,
                relationship: args.relationship,
              }, null, 2),
            }],
          };
        }

        case "unlink": {
          if (!args.source_id || !args.target_id) {
            throw new Error("source_id and target_id required");
          }

          const id = `link_${args.source_id}_${args.target_id}`;
          await deletePoints(COLLECTIONS.LINKS, [id]);

          return {
            content: [{
              type: "text" as const,
              text: JSON.stringify({ success: true, message: "Link removed" }, null, 2),
            }],
          };
        }

        case "traverse": {
          if (!args.start_id) throw new Error("start_id required");

          const maxDepth = args.max_depth || 2;
          const visited = new Set<string>();
          const graph: Record<string, any[]> = {};

          async function traverseLevel(nodeId: string, depth: number) {
            if (depth > maxDepth || visited.has(nodeId)) return;
            visited.add(nodeId);

            // Find links from this node
            const outgoingFilter = { must: [{ key: "source_id", match: { value: nodeId } }] };
            const outgoing = await scrollPoints(COLLECTIONS.LINKS, outgoingFilter, 50);

            // Find links to this node
            const incomingFilter = { must: [{ key: "target_id", match: { value: nodeId } }] };
            const incoming = await scrollPoints(COLLECTIONS.LINKS, incomingFilter, 50);

            graph[nodeId] = [
              ...outgoing.map((l: any) => ({
                direction: "outgoing",
                target: l.payload?.target_id,
                relationship: l.payload?.relationship,
                strength: l.payload?.strength,
              })),
              ...incoming.map((l: any) => ({
                direction: "incoming",
                source: l.payload?.source_id,
                relationship: l.payload?.relationship,
                strength: l.payload?.strength,
              })),
            ];

            // Filter by relationship type if specified
            if (args.relationship_filter?.length) {
              graph[nodeId] = graph[nodeId].filter(
                (link) => args.relationship_filter!.includes(link.relationship)
              );
            }

            // Recurse
            for (const link of graph[nodeId]) {
              const nextId = link.direction === "outgoing" ? link.target : link.source;
              if (nextId) await traverseLevel(nextId, depth + 1);
            }
          }

          await traverseLevel(args.start_id, 0);

          return {
            content: [{
              type: "text" as const,
              text: JSON.stringify({
                success: true,
                start_id: args.start_id,
                nodes_visited: visited.size,
                graph,
              }, null, 2),
            }],
          };
        }

        case "cluster": {
          if (!args.query) throw new Error("Query required for clustering");

          const embedding = await generateEmbedding(args.query);
          if (!embedding) throw new Error("Failed to generate embedding");

          // Get candidate memories
          const candidates = await searchPoints(
            COLLECTIONS.LONG_TERM,
            embedding,
            50,
            args.similarity_threshold || 0.85
          ) as any[];

          if (candidates.length < (args.min_cluster_size || 3)) {
            return {
              content: [{
                type: "text" as const,
                text: JSON.stringify({
                  success: true,
                  message: "Not enough similar memories for clustering",
                  candidates_found: candidates.length,
                  min_required: args.min_cluster_size || 3,
                }, null, 2),
              }],
            };
          }

          // Simple clustering: group by high similarity
          const cluster = {
            members: candidates.map((c: any) => ({
              id: c.id,
              content: c.payload?.content,
              score: c.score,
            })),
            summary_preview: candidates.map((c: any) => c.payload?.content?.substring(0, 50)).join(" | "),
          };

          if (args.action === "identify") {
            return {
              content: [{
                type: "text" as const,
                text: JSON.stringify({
                  success: true,
                  action: "identify",
                  cluster,
                }, null, 2),
              }],
            };
          }

          if (args.action === "summarize") {
            // Create summary (simple concatenation - in production, use LLM)
            const contents = candidates.map((c: any) => c.payload?.content).filter(Boolean);
            const summary = `[CLUSTER SUMMARY - ${contents.length} memories]\n\n` +
              contents.map((c: string, i: number) => `${i + 1}. ${c}`).join("\n\n");

            const summaryEmbedding = await generateEmbedding(summary);
            if (!summaryEmbedding) throw new Error("Failed to generate summary embedding");

            const summaryId = generateUUID();
            await storePoint(COLLECTIONS.LONG_TERM, summaryId, summaryEmbedding, {
              content: summary,
              type: "context",
              is_cluster_summary: true,
              member_ids: candidates.map((c: any) => c.id),
              created_at: new Date().toISOString(),
              tier: "long_term",
            });

            return {
              content: [{
                type: "text" as const,
                text: JSON.stringify({
                  success: true,
                  action: "summarize",
                  summary_id: summaryId,
                  members_summarized: candidates.length,
                  message: "Cluster summarized. Original memories preserved.",
                }, null, 2),
              }],
            };
          }

          if (args.action === "merge") {
            // Merge into single memory, delete originals
            const contents = candidates.map((c: any) => c.payload?.content).filter(Boolean);
            const merged = contents.join("\n\n---\n\n");

            const mergedEmbedding = await generateEmbedding(merged);
            if (!mergedEmbedding) throw new Error("Failed to generate merged embedding");

            const mergedId = generateUUID();
            await storePoint(COLLECTIONS.LONG_TERM, mergedId, mergedEmbedding, {
              content: merged,
              type: "context",
              is_merged: true,
              source_ids: candidates.map((c: any) => c.id),
              created_at: new Date().toISOString(),
              tier: "long_term",
            });

            // Delete originals
            const idsToDelete = candidates.map((c: any) => c.id);
            await deletePoints(COLLECTIONS.LONG_TERM, idsToDelete);

            return {
              content: [{
                type: "text" as const,
                text: JSON.stringify({
                  success: true,
                  action: "merge",
                  merged_id: mergedId,
                  memories_merged: idsToDelete.length,
                }, null, 2),
              }],
            };
          }

          return {
            content: [{
              type: "text" as const,
              text: JSON.stringify({ success: true, cluster }, null, 2),
            }],
          };
        }

        case "prune": {
          if (!args.criteria) throw new Error("Criteria required for pruning");

          const dryRun = args.dry_run !== false;

          // Build filter based on criteria
          const must: Record<string, unknown>[] = [];

          if (args.criteria.older_than_days) {
            const cutoff = new Date(Date.now() - args.criteria.older_than_days * 24 * 60 * 60 * 1000);
            must.push({
              key: "created_at",
              range: { lt: cutoff.toISOString() },
            });
          }

          // Get candidates
          const filterObj = must.length > 0 ? { must } : undefined;
          const candidates = await scrollPoints(COLLECTIONS.LONG_TERM, filterObj, 1000) as any[];

          // Further filter in code
          let toDelete = candidates;

          if (args.criteria.superseded) {
            // Find memories that have been superseded
            const supersededLinks = await scrollPoints(COLLECTIONS.LINKS, {
              must: [{ key: "relationship", match: { value: "supersedes" } }],
            }, 1000);
            const supersededIds = new Set(supersededLinks.map((l: any) => l.payload?.target_id));
            toDelete = toDelete.filter((m: any) => supersededIds.has(m.id));
          }

          const pruneList = toDelete.map((m: any) => ({
            id: m.id,
            content_preview: m.payload?.content?.substring(0, 100),
            created_at: m.payload?.created_at,
          }));

          if (dryRun) {
            return {
              content: [{
                type: "text" as const,
                text: JSON.stringify({
                  success: true,
                  dry_run: true,
                  would_delete: pruneList.length,
                  candidates: pruneList.slice(0, 10),
                  message: "Set dry_run=false to actually delete",
                }, null, 2),
              }],
            };
          }

          // Actually delete
          const idsToDelete = toDelete.map((m: any) => m.id);
          if (idsToDelete.length > 0) {
            await deletePoints(COLLECTIONS.LONG_TERM, idsToDelete);
          }

          return {
            content: [{
              type: "text" as const,
              text: JSON.stringify({
                success: true,
                deleted: idsToDelete.length,
              }, null, 2),
            }],
          };
        }

        default:
          throw new Error(`Unknown operation: ${operation}`);
      }
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : "Unknown error";
      return {
        content: [{ type: "text" as const, text: `Error in memory organization: ${errorMessage}` }],
        isError: true,
      };
    }
  }
);

// Start server
async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error("Claude Memory MCP Server v3.0 running (compound intelligence enabled)");
}

main().catch((error) => {
  console.error("Fatal error:", error);
  process.exit(1);
});
