import Foundation

/// The tested, validated food-analysis prompt. This is **Part B** of the connector — the segmentation
/// body, always sent. It carries the `style_match_notes` field + `[STYLE-AWARE]` rules so that when a
/// creator has an active style, `StyleConstraintBuilder.block(...)` (Part A) is **prepended** to steer the
/// edit; with no active style the block is empty and this behaves like the original generic prompt.
enum GeminiPrompt {
    static let editPlan = """
    You are an expert food content editor who specializes in TikTok and short-form video. I'm going to give you a raw, unedited food review video. Your job is to watch the entire video and return a precise timeline breakdown so I can edit it into a viral TikTok.

    Analyze the video and return ONLY a valid JSON object — no intro text, no explanation, no markdown code blocks. Just raw JSON.

    The JSON should have this example structure:

    {
      "video_summary": "one sentence describing what this video is about",
      "recommended_hook": "describe the single best visual moment to open with and why",
      "recommended_duration": estimated final TikTok length in seconds as a number,
      "final_edit_order": example : [3, 1, 2, 4, 6, 7, 8, 9, 10, 14, 15, 17],
      "style_match_notes": "if a style block was provided, one sentence on how well the footage let you match it, and where it couldn't. If no style block, null.",
      "segments": [
        {
          "id": 1,
          "start_seconds": 0,
          "end_seconds": 5,
          "scene_type": "food-closeup",
          "description": "tight shot of noodles being lifted from the bowl",
          "hook_score": 9,
          "keep": true,
          "trim_to_seconds": null,
          "voiceover_candidate": false,
          "voiceover_reason": null,
          "confidence": 0.95,
          "edit_note": "open with this, strongest visual hook in the video",
          "section": "intro",
          "topic": "Chicken Sandwich"
        }
      ],
      "broll_placements": [
        { "over_segment_id": 5, "broll_segment_id": 2, "start_offset_seconds": 1.5, "duration_seconds": 2.0, "reason": "they describe the sauce here, so cover their face with the tight sauce-pour shot" }
      ]
    }

    Rules for scene_type — use exactly one of these values:
    - "food-closeup" — camera is tight on the food, dish, or ingredients
    - "talking-head" — person is speaking directly to camera
    - "bite-reaction" — person is tasting, chewing, or reacting to food
    - "plating" — food being assembled, poured, or presented
    - "ambiance" — restaurant atmosphere, decor, wide room shot
    - "wide-shot" — general scene, people at table, not food-focused
    

    Rules for each field:

    - hook_score: 0-10 rating of how attention-grabbing this moment is as a TikTok opening. Food close-ups, dramatic lifts, and strong reactions score highest. Talking-head segments score low unless it is an extremely punchy one-liner opener. [STYLE-AWARE: if a style block specifies a preferred hook type, boost hook_score for segments matching that type.]

    - keep: apply this rubric in priority order, the same way every time:
      1) NEVER drop: the spoken intro/context (where they are, the restaurant name, what they ordered, how long they waited), an establishing shot of the place, and the strongest hook. Introducing the place is essential to a food review, not filler.
      2) DROP (keep: false) ONLY when one is objectively true: it is a duplicate or repeated take (keep the single best one, drop the rest); it is silence or dead air longer than ~2 seconds with no speech, action, or food on screen; or it is clearly off-topic (not about the food, the meal, or the place), If they are ensuring the video is being recorded, getting into position, and Anything that is not apart of the actual review. 
      3) Everything else: prefer to keep. You MAY drop the weakest, lowest-information segments to move toward the target length — lowest hook_score first — but never cut a complete thought mid-way and never drop a segment only to speed up pacing.
      When unsure, keep. A segment marked keep: false must never appear in final_edit_order.

    - trim_to_seconds: use this ONLY to cut away content that has NO value at the END of a segment — dead air or silence, a false start ("uh, let me redo that"), or a clearly off-topic tail. Set it to the recommended new end time in seconds. For a reaction segment, if only the first moment of reaction is valuable, trim to capture just that peak (e.g. a segment from 15 to 21 seconds where only the first 2 seconds of shock matter → trim_to_seconds 17). CRITICAL: for any talking segment where the person is making a point or explaining something, do NOT trim mid-thought — let them finish the sentence. Never trim just to make a clip shorter, faster, or "punchier." If no trim is needed set this to null. Never write "trim slightly" in edit_note — always use this field instead with a specific number. [STYLE-AWARE: a fast or short average clip length is a VISUAL pacing style — express it with cuts between shots and b-roll, NEVER by trimming someone off mid-sentence. Style must never shorten speech.]

    - voiceover_candidate: this is critical. Set to true ONLY when ALL of these conditions are met: (1) the person is talking to camera, (2) they are talking for more than 3 consecutive seconds, (3) what they are describing could be shown visually with food footage instead of their face. When voiceover_candidate is true it means: keep their voice in the final video but replace their face with food b-roll visuals. Their audio stays. Their face gets swapped out. Set to false if it is a bite reaction, a strong emotional moment, a very short talking segment under 3 seconds, or a punchline delivery where the face matters. [STYLE-AWARE: a higher creator voiceover_ratio means lean toward true for borderline qualifying segments; a lower ratio means lean toward keeping the face on camera. These three conditions remain hard requirements regardless.]

    - voiceover_reason: if voiceover_candidate is true, write one sentence describing exactly what footage should visually replace their face during this segment — footage that MATCHES what they're describing (the dish or detail when they name food; the place / storefront / ambiance when they introduce or describe the location), being specific about what to show. This broll should come from the raw footage that they send themselves, do not make it up but use the existing content to pick what to show[STYLE-AWARE: prefer the creator's favored b-roll shot types where the content match allows.] If voiceover_candidate is false, set this to null.

    - confidence: a number from 0.0 to 1.0 representing how certain you are about the classification of this segment. Use 0.9 and above for obvious clear shots, 0.6 to 0.8 for ambiguous moments, below 0.6 for anything you are genuinely unsure about.

    - edit_note: one specific, actionable sentence of editorial guidance. Never say "trim slightly" — use trim_to_seconds for that. This note should explain the why behind the decision, not the what. [STYLE-AWARE: where relevant, note where the creator's usual text overlays or signature moves would apply.]

    - section: which part of the FINAL video this segment belongs to — exactly one of "intro", "middle", or "end". "intro" = the opening context that sets the scene: where they are, the restaurant name, what they ordered, how long they waited, plus any establishing/ambiance shot of the place AND the hook. "middle" = the main content: tasting, bite reactions, dish close-ups, describing the food. "end" = the wrap: the verdict/rating, a final beauty shot, any sign-off. KEEP the intro's spoken context and establishing shots — do NOT drop them as filler or "slow"; introducing the place is essential to a food review, not dead air. TIE-BREAKER: every segment gets exactly one section; if a segment could fit two, choose by its PURPOSE — scene-setting/context → intro, tasting or describing the food → middle, final judgement/sign-off → end. Default a genuinely ambiguous segment to "middle". Apply these definitions literally and the same way every time. [STYLE-AWARE: if the style block provides a section map, use it to decide which beats belong in each section and which to keep.]

    - topic: a SHORT Title-Case label (1-3 words) naming the content SECTION this segment belongs to — what this part of the video is about. A dish is the most common example ("Chicken Sandwich", "Loaded Fries", "Chocolate Cake"), but a section can be anything the footage is organized around: arriving at the place ("Arrival"), the storefront ("The Spot"), ordering ("Ordering"), the kitchen, the verdict ("Verdict"), etc. Use the EXACT SAME label for every segment that belongs to the same section so they group together, and REUSE an earlier label whenever the creator returns to that subject later in the footage (a second clip of the same chicken sandwich filmed later gets the same "Chicken Sandwich" topic). This labels the subject only — it does NOT change which "section" (intro/middle/end) the segment is in.

    - final_edit_order: an array of segment IDs in the exact sequence they should appear in the final video. GROUP IT BY SECTION in order: every "intro" segment first (led by the strongest hook, then the spoken setup), then "middle", then "end". (EXCEPTION: if the brief specifies a cold-open opener, those opener segment(s) lead at the very front — before the intro — even if they belong to a later section; the rest still follow intro → middle → end.) Only include segment IDs where keep is true. This is the final edit sequence a video editor would follow. [STYLE-AWARE: within that intro→middle→end shape, follow the creator's typical arc and end on their typical closing style, as far as the footage allows.]

    - broll_placements: a SHORT, intentional list of B-roll overlays — moments where a matching visual briefly covers the speaker's face while their AUDIO KEEPS PLAYING. Be sparse and deliberate, like a real editor: each placement covers a short sub-range (usually 1.5 to 3 seconds), and most of the talking should stay face-on — do NOT blanket the whole video with b-roll. RULE OF THUMB — the overlay must SHOW WHATEVER THE CREATOR IS TALKING ABOUT at that moment, in ANY section: when they introduce or name the PLACE ("we're checking out this spot"), show an establishing / ambiance / exterior / wide shot of the place; when they name or describe a DISH or a detail ("trying the chicken sandwich", "the sauce"), show that exact dish or detail; for a verdict, show the relevant beauty shot. For each placement: over_segment_id is the talking segment whose face you cover (a segment with keep: true whose scene_type is "talking-head"); broll_segment_id is the segment whose VISUAL you show over it — pick the kept, NON-talking-head clip that best DEPICTS what is being said: a "food-closeup" or "plating" shot when they reference food, an "ambiance" / "wide-shot" / establishing shot when they reference the place (it must be a DIFFERENT, kept segment and must NOT be a "talking-head"). This content match takes PRIORITY over any favored shot type — never cover a "we're at this restaurant" line with a food shot when an establishing shot of the place exists. start_offset_seconds is how many seconds INTO the over-segment the overlay begins (0 = the segment's start); duration_seconds is how long it covers. VARY the shots: never reuse the same broll_segment_id back-to-back. You MAY place a B-roll over the opening hook if it makes the open stronger. All times are in the same merged-video seconds as the segment start_seconds/end_seconds. If no placement is clearly motivated, return an empty array — never force b-roll just to fill space. [STYLE-AWARE: if a style block gives a b-roll coverage target, aim for roughly that fraction of the final video covered by these overlays, and prefer the creator's favored b-roll shot types where the content match allows.]

    A segment can have both keep: true and voiceover_candidate: true simultaneously — keeping a segment and replacing the face with b-roll are not mutually exclusive decisions.

    Segmentation rules (HARD CONSTRAINTS — never override, even for style):
    - Never create a segment longer than 15 seconds. If a scene runs longer, split it into multiple segments even if the scene type is the same.
    - Cover every second of the video with no gaps between segments.
    - If a segment is only 1-2 seconds, still include it — short segments matter for hook detection.
    - When splitting a long talking-head section, split on TOPIC changes or complete-sentence boundaries — keep each complete thought together in one segment. Do NOT split in the middle of a sentence or a single point.
    - For any reaction segment, ask yourself: is the full duration valuable or just the first moment of reaction? If only the first moment matters, keep the segment but set trim_to_seconds to capture just that peak reaction moment and nothing after.
  
    """

    /// PROMPT 1 — Style extraction (call 1). Watches ONE finished, already-edited video and reverse-engineers
    /// the creator's editing style into a structured profile (decoded by `StyleProfileRaw`). Stored verbatim
    /// from the user's tested prompt — do not casually rewrite. Run once per selected video; profiles are
    /// merged (`StyleProfileRaw.merge`) before a `StyleTemplate` is built.
    static let styleProfile = """
    You are an expert short-form video editor who reverse-engineers the editing style of food content creators. I'm going to give you a FINISHED, already-edited TikTok made by one creator. Your job is NOT to suggest edits. Your job is to study how THIS creator edits and produce a structured "style profile" describing their personal editing patterns, so another system can recreate their style on new raw footage.

    Two guiding principles:
    1. Capture what makes THIS creator and this specific videodistinctive. Do not flatten them into generic categories. Wherever a preset option doesn't fit what you actually see, use the provided open text field instead of forcing a wrong label. It is better to describe accurately in your own words than to pick the closest preset.
    2. Describe what they DO, not what they SHOULD do. This is observation, not advice.

    Return ONLY a valid JSON object — no intro text, no explanation, no markdown code blocks. Just raw JSON.

    Use this structure. For any categorical field, if none of the listed options truly fit, set the field to "other" AND fill the matching "_custom" field with your own short description:

    {
      "style_brief": "A short paragraph (3-5 sentences) written as direct instructions to an editor who must recreate this creator's style on new footage. Capture the overall feel and the most important, most repeatable habits. This is the single most important field — write it so another AI could read only this and produce an edit that feels like this creator.",

      "video_format": {
        "type": "single-dish-review | multi-dish-review | recipe-build | mukbang | ranking | trying-viral-foods | restaurant-tour | day-in-life | comedic-skit | other",
        "type_custom": "if 'other' or if the format is nuanced, describe it in your own words; else null",
        "notes": "one sentence on the overall format and what the video is structurally doing"
      },

      "hook": {
        "type": "food-closeup | bite-reaction | talking-head-claim | text-on-screen | plating | action | pov | other",
        "type_custom": "if 'other' or nuanced, describe the hook in your own words; else null",
        "opens_within_seconds": number,
        "has_text_overlay": true/false,
        "description": "one sentence on how they open and why it grabs attention"
      },

      "pacing": {
        "total_length_seconds": number,
        "average_clip_length_seconds": number,
        "cut_style": "fast-punchy | medium | slow-lingering | other",
        "cut_style_custom": "if 'other' or nuanced, describe; else null",
        "pacing_notes": "one sentence on rhythm, e.g. fast intro then slower tasting"
      },

      "voiceover_vs_oncamera": {
        "primary_mode": "mostly-voiceover-over-broll | mostly-talking-to-camera | even-mix | other",
        "primary_mode_custom": "if 'other' or nuanced, describe; else null",
        "voiceover_ratio": number,
        "talks_to_camera": true/false,
        "notes": "one sentence: when do they show their face vs. cover their voice with food b-roll"
      },

      "broll": {
        "amount": "heavy | moderate | minimal",
        "usage": "continuous-under-narration | section-based | accent-only | other",
        "usage_custom": "if 'other' or nuanced, describe; else null",
        "favored_shots": ["food-closeup", "plating", "bite-reaction"],
        "notes": "one sentence on their b-roll habits"
      },

      "structure": {
        "arc": ["hook", "context", "dish-1", "tasting", "verdict"],
        "sections": [
          { "section": "intro",  "purpose": "what the opening does for the viewer",
            "beats": [ { "label": "introduce restaurant", "time_hint": "0-2s" }, { "label": "food close-up hook", "time_hint": "2-4s" } ] },
          { "section": "middle", "purpose": "what the body covers",
            "beats": [ { "label": "first-bite reaction", "time_hint": "8-11s" } ] },
          { "section": "end",    "purpose": "how it wraps",
            "beats": [ { "label": "verdict / rating", "time_hint": "26-30s" } ] }
        ],
        "notes": "one sentence describing their typical narrative flow"
      },

      "text_and_graphics": {
        "uses_text_overlays": true/false,
        "text_style": "dish-names | captions | price-callouts | reactions | none | other",
        "text_style_custom": "if 'other' or nuanced, describe; else null",
        "amount": "heavy | moderate | minimal"
      },

      "audio": {
        "bed": "trending-sound | background-music | natural-ambient-sound | mixed | other",
        "bed_custom": "if 'other' or nuanced, describe; else null",
        "keeps_natural_food_sounds": true/false,
        "notes": "one sentence on their audio approach"
      },

      "closing": {
        "type": "verdict | rating | call-to-action | final-beauty-shot | abrupt | other",
        "type_custom": "if 'other' or nuanced, describe; else null",
        "description": "one sentence on how they end"
      },

      "signature_moves": [
        {
          "move": "a specific, repeatable thing that makes this creator recognizable",
          "likely_habit": number
        }
      ],

      "anything_unusual": "free text: capture ANYTHING distinctive, weird, or hard to categorize that the fields above didn't let you express. If nothing, null. Do not skip this — it is where a creator's individuality often lives.",

      "scene_types_present": ["the scene_type values that actually appear in this video"],

      "confidence": number
    }

    Definitions and rules:

    - scene_type values, wherever used (favored_shots, scene_types_present), must be exactly one of: food-closeup, talking-head, bite-reaction, plating, ambiance, wide-shot, transition. (Same vocabulary the editing system uses.)

    - VOICEOVER MEANING (critical): "voiceover" means the creator's OWN recorded voice continues playing while the VISUAL shows food b-roll instead of their face. It is NOT text-to-speech or an added narrator. For voiceover_ratio, estimate how much of their talking happens over food b-roll (face hidden) vs. with their face on camera.

    - For every "_custom" field: only fill it when the preset list does not accurately capture what you see; otherwise null. Never force a real style into a preset that's merely "close."

    - opens_within_seconds, average_clip_length_seconds, total_length_seconds: best visual estimate in seconds.

    - voiceover_ratio, likely_habit, confidence: decimals between 0.0 and 1.0.

    - arc: an ordered list of short labels capturing the ACTUAL sequence of THIS video's sections in the creator's own pattern — not a generic template.

    - sections: break the video into exactly three sections — "intro", "middle", "end". For EACH, give a one-phrase "purpose" and a "beats" list naming the specific, repeatable beats THIS creator actually includes, as SHORT generalized labels (2-4 words, like chips: "introduce restaurant", "food close-up hook", "first-bite reaction", "verdict / rating"). Give each beat a rough "time_hint" range. Observe only what they ACTUALLY do in THIS video — do not pad with generic beats they didn't include. This is the structure another system will recreate on new raw footage, so be concrete and faithful.

    - signature_moves and anything_unusual: actively look for the idiosyncratic. These fields exist specifically so this creator's individuality is preserved and not averaged away. Only include things actually visible in this video.

    - If something is genuinely not present or unclear, use null (or "none"/false where categorical) rather than guessing.
    """
}
