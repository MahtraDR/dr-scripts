require_relative 'spec_helper'

# ScrollStack#initialize depends on the full Lich runtime (get_settings,
# parse_args, and live stacker I/O), so we extract the class with load_lic_class
# and exercise the pure, side-effect-free seams on bare-allocated instances
# (ScrollStack.allocate). Every example is self-contained and reads top-to-bottom
# (DAMP).
#
# The emphasis is adversarial: boundary counts, blank/nil inputs, the EXACT
# name-or-abbreviation matching contract (no substring), the stow-by-default
# excess policy, the Q1 per-slot limit rule, and the B3/B5 data-safety fixes.
# These are the seams where a wrong answer silently trashes a player's scrolls.
load_lic_class('stack-scrolls.lic', 'ScrollStack')

# UserVars is per-script configuration -- the spec_helper convention is to stub it
# per spec rather than in the shared harness. Provide the constant (only if no
# other spec already defined it) so `allow(UserVars).to receive(:stackers)` has a
# target regardless of load order.
class UserVars
  class << self
    def stackers; @stackers; end
    def stackers=(value); @stackers = value; end
  end
end unless defined?(UserVars)

RSpec.describe ScrollStack do
  subject(:script) { described_class.allocate }

  # Small readable builder for a stacker cache entry.
  def stacker(name, contents)
    { 'name' => name, 'contents' => contents }
  end

  # ===========================================================================
  # blank? / slot_empty? -- the nil/empty predicates everything else leans on
  # ===========================================================================
  describe '#blank?' do
    it 'treats nil as blank' do
      expect(script.blank?(nil)).to be(true)
    end

    it 'treats an empty and a whitespace-only string as blank' do
      expect(script.blank?('')).to be(true)
      expect(script.blank?('   ')).to be(true)
    end

    it 'treats a real string as present' do
      expect(script.blank?('Fireball')).to be(false)
    end

    it 'treats a non-string (which cannot be blank) as present' do
      expect(script.blank?(42)).to be(false)
    end
  end

  describe '#slot_empty?' do
    it 'treats nil and [] as an empty slot' do
      expect(script.slot_empty?(nil)).to be(true)
      expect(script.slot_empty?([])).to be(true)
    end

    it 'treats a populated [spell, count] slot as occupied' do
      expect(script.slot_empty?(['Fireball', 5])).to be(false)
    end
  end

  # ===========================================================================
  # pick / resolve_bool_setting -- settings access, including the false trap
  # ===========================================================================
  describe '#pick' do
    it 'reads a string key' do
      expect(script.pick({ 'stackers' => ['a'] }, 'stackers')).to eq(['a'])
    end

    it 'falls back to the symbol key' do
      expect(script.pick({ stackers: ['a'] }, 'stackers')).to eq(['a'])
    end

    it 'returns nil when absent under both forms' do
      expect(script.pick({}, 'stackers')).to be_nil
    end

    it 'treats an explicit false as absent (why resolve_bool_setting exists)' do
      # Documents a sharp corner: pick uses ||, so a false string value falls
      # through to the symbol value. Booleans must go through resolve_bool_setting.
      expect(script.pick({ 'flag' => false, flag: true }, 'flag')).to be(true)
    end
  end

  describe '#resolve_bool_setting' do
    it 'honors an explicit false instead of the default' do
      expect(script.resolve_bool_setting({ 'trash_excess_scrolls' => false }, 'trash_excess_scrolls', true)).to be(false)
    end

    it 'honors an explicit true' do
      expect(script.resolve_bool_setting({ 'k' => true }, 'k', false)).to be(true)
    end

    it 'reads the symbol form when the string form is unset' do
      expect(script.resolve_bool_setting({ k: false }, 'k', true)).to be(false)
    end

    it 'uses the default only when unset under both forms' do
      expect(script.resolve_bool_setting({}, 'k', true)).to be(true)
    end
  end

  # ===========================================================================
  # Settings normalization -- the stow-by-default and opt-in-logging contract
  # ===========================================================================
  describe '#normalize_new_config' do
    it 'defaults trash_excess_scrolls to false (STOW), not trash' do
      config = script.normalize_new_config('stackers' => ['scroll.folio'])
      expect(config[:trash_excess_scrolls]).to be(false)
    end

    it 'still honors an explicit trash_excess_scrolls: true' do
      config = script.normalize_new_config('stackers' => ['s'], 'trash_excess_scrolls' => true)
      expect(config[:trash_excess_scrolls]).to be(true)
    end

    it 'defaults log_statistics to false (opt-in)' do
      config = script.normalize_new_config('stackers' => ['s'])
      expect(config[:log_statistics]).to be(false)
    end

    it 'accepts symbol keys and passes through stackers and limits' do
      config = script.normalize_new_config(stackers: ['a', 'b'], max_scrolls_per_spell: 100, max_scrolls_per_slot: 125)
      expect(config[:scroll_stackers]).to eq(['a', 'b'])
      expect(config[:max_scrolls_per_spell]).to eq(100)
      expect(config[:max_scrolls_per_slot]).to eq(125)
    end

    it 'defaults keep/discard lists to empty arrays' do
      config = script.normalize_new_config('stackers' => ['s'])
      expect(config[:keep_scrolls]).to eq([])
      expect(config[:discard_scrolls]).to eq([])
    end
  end

  describe '#normalize_legacy_config' do
    it 'defaults trash_excess_scrolls to false (STOW) when the key is absent' do
      settings = OpenStruct.new(scroll_stackers: ['s'])
      expect(script.normalize_legacy_config(settings)[:trash_excess_scrolls]).to be(false)
    end

    it 'honors an explicit legacy trash_excess_scrolls: true' do
      settings = OpenStruct.new(scroll_stackers: ['s'], trash_excess_scrolls: true)
      expect(script.normalize_legacy_config(settings)[:trash_excess_scrolls]).to be(true)
    end

    it 'honors an explicit legacy trash_excess_scrolls: false' do
      settings = OpenStruct.new(scroll_stackers: ['s'], trash_excess_scrolls: false)
      expect(script.normalize_legacy_config(settings)[:trash_excess_scrolls]).to be(false)
    end

    it 'forces limit features off and logging off in legacy mode' do
      config = script.normalize_legacy_config(OpenStruct.new(scroll_stackers: ['s']))
      expect(config[:max_scrolls_per_spell]).to be_nil
      expect(config[:max_scrolls_per_slot]).to be_nil
      expect(config[:log_statistics]).to be(false)
    end
  end

  # ===========================================================================
  # effective_patterns / matches_any_pattern? -- EXACT name-or-abbrev matching
  # (the highest-stakes change: a wrong answer trashes scrolls)
  # ===========================================================================
  describe '#effective_patterns' do
    it 'drops blank and whitespace-only patterns (B3)' do
      expect(script.effective_patterns(['Fire', '', '  ', 'Heal'])).to eq(['Fire', 'Heal'])
    end

    it 'treats nil as an empty list' do
      expect(script.effective_patterns(nil)).to eq([])
    end
  end

  describe '#matches_any_pattern?' do
    it 'matches a full spell name exactly, case-insensitively' do
      expect(script.matches_any_pattern?('Fireball', ['fireball'])).to be(true)
    end

    it 'does NOT match on a substring (the whole point of exact matching)' do
      expect(script.matches_any_pattern?('Fireball', ['Fire'])).to be(false)
    end

    it 'does NOT let a spell name that contains a pattern match it' do
      expect(script.matches_any_pattern?('Self Heal', ['Heal'])).to be(false)
    end

    it 'matches on the abbreviation exactly when provided' do
      expect(script.matches_any_pattern?('Fireball', ['fb'], abbrev: 'FB')).to be(true)
    end

    it 'does NOT match a partial abbreviation' do
      expect(script.matches_any_pattern?('Fireball', ['f'], abbrev: 'fb')).to be(false)
    end

    it 'ignores surrounding whitespace on both pattern and candidate' do
      expect(script.matches_any_pattern?('  Fire  ', [' Fire '])).to be(true)
    end

    it 'ignores blank patterns so they never match everything (B3)' do
      expect(script.matches_any_pattern?('Fireball', ['', '   '])).to be(false)
    end

    it 'returns false when both the name and abbreviation are blank' do
      expect(script.matches_any_pattern?('', ['Fire'], abbrev: nil)).to be(false)
    end
  end

  # ===========================================================================
  # keep_spell? -- blacklist wins, empty-whitelist-keeps-all, exact matching
  # ===========================================================================
  describe '#keep_spell?' do
    it 'keeps everything when both lists are empty' do
      expect(script.keep_spell?('Fireball', keep_list: [], discard_list: [])).to be(true)
    end

    it 'lets the blacklist win even over the whitelist' do
      expect(script.keep_spell?('Fire', keep_list: ['Fire'], discard_list: ['Fire'])).to be(false)
    end

    it 'trashes a spell that is not in a non-empty whitelist' do
      expect(script.keep_spell?('Heal', keep_list: ['Fire'], discard_list: [])).to be(false)
    end

    it 'does NOT keep Fireball just because Fire is whitelisted (exact only)' do
      expect(script.keep_spell?('Fireball', keep_list: ['Fire'], discard_list: [])).to be(false)
    end

    it 'keeps a spell matched exactly by name' do
      expect(script.keep_spell?('Fire', keep_list: ['fire'], discard_list: [])).to be(true)
    end

    it 'keeps a spell matched by its abbreviation' do
      expect(script.keep_spell?('Heal', abbrev: 'heal', keep_list: ['HEAL'], discard_list: [])).to be(true)
    end

    it 'discards a spell matched by its abbreviation' do
      expect(script.keep_spell?('Fireball', abbrev: 'fb', keep_list: [], discard_list: ['fb'])).to be(false)
    end

    it 'keeps everything when the keep list contains only blank entries (B3)' do
      # Regression guard: a whitelist of [""] must not be treated as "keep only
      # the empty spell" and thus trash the whole collection.
      expect(script.keep_spell?('Fireball', keep_list: ['', '  '], discard_list: [])).to be(true)
    end

    it 'ignores blank discard entries so they cannot trash everything (B3)' do
      expect(script.keep_spell?('Fireball', keep_list: [], discard_list: ['', ' '])).to be(true)
    end
  end

  # ===========================================================================
  # parse_section_line -- flip output parsing
  # ===========================================================================
  describe '#parse_section_line' do
    it 'parses a populated section into [spell, count]' do
      expect(script.parse_section_line('The Fireball section has 5 scrolls')).to eq(['Fireball', 5])
    end

    it 'parses a multi-word spell name' do
      expect(script.parse_section_line('The Rage of the Clans section has 12 scrolls')).to eq(['Rage of the Clans', 12])
    end

    it 'parses a zero-count section as [spell, 0]' do
      expect(script.parse_section_line('The Fire section has 0 scrolls')).to eq(['Fire', 0])
    end

    it 'parses an empty section marker into []' do
      expect(script.parse_section_line('Section 3 is empty')).to eq([])
    end

    it 'returns nil for nil and for unrelated lines' do
      expect(script.parse_section_line(nil)).to be_nil
      expect(script.parse_section_line('You see nothing unusual.')).to be_nil
    end
  end

  # ===========================================================================
  # Scroll identification parsing (B2)
  # ===========================================================================
  describe '#glyph_scroll?' do
    it 'is true for the three-dimensional-shapes glyph text' do
      expect(script.glyph_scroll?('three-dimensional shapes cover much of the scroll')).to be(true)
    end

    it 'is false for a normal look and for nil' do
      expect(script.glyph_scroll?('It is labeled "Heal".')).to be(false)
      expect(script.glyph_scroll?(nil)).to be(false)
    end
  end

  describe '#spell_from_look' do
    it 'extracts a labeled spell name whether the period is outside the quote' do
      expect(script.spell_from_look('It is labeled "Rage of the Clans".')).to eq('Rage of the Clans')
    end

    it 'extracts a labeled spell name whether the period is inside the quote' do
      expect(script.spell_from_look('It is labeled "Rage of the Clans."')).to eq('Rage of the Clans')
    end

    it 'extracts a described spell name' do
      expect(script.spell_from_look('a scroll of the Heal spell.')).to eq('Heal')
    end

    it 'returns nil for glyph text, blank, and nil' do
      expect(script.spell_from_look('three-dimensional shapes cover much of the scroll')).to be_nil
      expect(script.spell_from_look('')).to be_nil
      expect(script.spell_from_look(nil)).to be_nil
    end
  end

  describe '#spell_from_read' do
    it 'extracts the spell from a glyph read result' do
      expect(script.spell_from_read('The scroll contains a complete description of the Heal spell')).to eq('Heal')
    end

    it 'returns nil when the read did not describe a spell' do
      expect(script.spell_from_read('I could not find')).to be_nil
      expect(script.spell_from_read(nil)).to be_nil
    end
  end

  # ===========================================================================
  # bucket_full? -- trash-bucket emptying timing
  # ===========================================================================
  describe '#bucket_full?' do
    let(:now) { Time.at(1_000_000) }

    it 'is false when the bucket is empty' do
      expect(script.bucket_full?(0, now, now)).to be(false)
    end

    it 'is false when no first-tap time has been recorded' do
      expect(script.bucket_full?(5, nil, now)).to be(false)
    end

    it 'is true at exactly the scroll limit (boundary)' do
      expect(script.bucket_full?(30, now, now)).to be(true)
    end

    it 'is false one below the scroll limit within the time window' do
      expect(script.bucket_full?(29, now, now + 5)).to be(false)
    end

    it 'is true at exactly the time limit (boundary)' do
      expect(script.bucket_full?(1, now, now + 30)).to be(true)
    end
  end

  # ===========================================================================
  # Limit math -- slot_counts_for_spell / has_empty_slot? / count / within_limits?
  # (Q1: never trash while a non-full or empty slot can take the scroll)
  # ===========================================================================
  describe '#slot_counts_for_spell' do
    it 'returns one count per slot holding the spell' do
      cache = [stacker('a', [['Heal', 125], ['Fire', 3], ['Heal', 5]])]
      expect(script.slot_counts_for_spell('Heal', cache)).to contain_exactly(125, 5)
    end

    it 'is empty for a spell not present, and nil-safe' do
      expect(script.slot_counts_for_spell('Heal', [stacker('a', [['Fire', 1]])])).to eq([])
      expect(script.slot_counts_for_spell('Heal', nil)).to eq([])
    end
  end

  describe '#count_scrolls_for_spell' do
    it 'sums copies across every stacker' do
      cache = [stacker('a', [['Heal', 10]]), stacker('b', [['Heal', 5], ['Fire', 2]])]
      expect(script.count_scrolls_for_spell('Heal', cache)).to eq(15)
    end

    it 'is zero for an absent spell and nil-safe' do
      expect(script.count_scrolls_for_spell('Heal', nil)).to eq(0)
    end
  end

  describe '#has_empty_slot?' do
    it 'is true when any stacker has an empty slot' do
      expect(script.has_empty_slot?([stacker('a', [['Fire', 1], []])])).to be(true)
    end

    it 'is false when every slot is occupied, and nil-safe' do
      expect(script.has_empty_slot?([stacker('a', [['Fire', 1]])])).to be(false)
      expect(script.has_empty_slot?(nil)).to be(false)
    end
  end

  describe '#within_limits?' do
    it 'allows a brand-new spell when no slot yet holds it' do
      cache = [stacker('a', [['Fire', 1], []])]
      expect(script.within_limits?('Heal', cache, max_per_spell: nil, max_per_slot: 125)).to be(true)
    end

    it 'rejects once the per-spell total reaches the cap (boundary)' do
      cache = [stacker('a', [['Heal', 100]])]
      expect(script.within_limits?('Heal', cache, max_per_spell: 100, max_per_slot: nil)).to be(false)
    end

    it 'allows when the per-spell total is one below the cap' do
      cache = [stacker('a', [['Heal', 99]])]
      expect(script.within_limits?('Heal', cache, max_per_spell: 100, max_per_slot: nil)).to be(true)
    end

    it 'keeps a scroll when one slot is full but another for the same spell has room (Q1)' do
      cache = [stacker('a', [['Heal', 125], ['Heal', 5]])]
      expect(script.within_limits?('Heal', cache, max_per_spell: nil, max_per_slot: 125)).to be(true)
    end

    it 'keeps a scroll when all matching slots are full but an empty slot exists (Q1)' do
      cache = [stacker('a', [['Heal', 125], []])]
      expect(script.within_limits?('Heal', cache, max_per_spell: nil, max_per_slot: 125)).to be(true)
    end

    it 'rejects when all matching slots are full and no empty slot remains (Q1)' do
      cache = [stacker('a', [['Heal', 125]])]
      expect(script.within_limits?('Heal', cache, max_per_spell: nil, max_per_slot: 125)).to be(false)
    end

    it 'allows anything when both limits are disabled' do
      cache = [stacker('a', [['Heal', 999]])]
      expect(script.within_limits?('Heal', cache, max_per_spell: nil, max_per_slot: nil)).to be(true)
    end
  end

  # ===========================================================================
  # compute_prune_plan -- categorization with exact matching + abbreviations
  # ===========================================================================
  describe '#compute_prune_plan' do
    it 'returns an empty plan for a nil cache' do
      plan = script.compute_prune_plan(nil, keep_list: [], discard_list: [], max_per_spell: nil)
      expect(plan).to eq(unwanted: [], over_limit: [], keep: [])
    end

    it 'flags a spell absent from a non-empty keep list as unwanted' do
      cache = [stacker('a', [['Fire', 3]])]
      plan = script.compute_prune_plan(cache, keep_list: ['Heal'], discard_list: [], max_per_spell: nil)
      expect(plan[:unwanted].map { |s| s[:spell] }).to eq(['Fire'])
      expect(plan[:keep]).to be_empty
    end

    it 'does NOT spare Fireball under a keep list of ["Fire"] (exact only)' do
      cache = [stacker('a', [['Fireball', 2]])]
      plan = script.compute_prune_plan(cache, keep_list: ['Fire'], discard_list: [], max_per_spell: nil)
      expect(plan[:unwanted].map { |s| s[:spell] }).to eq(['Fireball'])
    end

    it 'spares a spell matched by abbreviation via the abbrevs map' do
      cache = [stacker('a', [['Fireball', 2]])]
      plan = script.compute_prune_plan(cache, keep_list: ['fb'], discard_list: [], max_per_spell: nil,
                                              abbrevs: { 'Fireball' => 'fb' })
      expect(plan[:unwanted]).to be_empty
      expect(plan[:keep].map { |s| s[:spell] }).to eq(['Fireball'])
    end

    it 'keeps everything when the keep list is only blanks (B3)' do
      cache = [stacker('a', [['Fire', 1], ['Heal', 1]])]
      plan = script.compute_prune_plan(cache, keep_list: ['', '  '], discard_list: [], max_per_spell: nil)
      expect(plan[:unwanted]).to be_empty
      expect(plan[:keep].size).to eq(2)
    end

    it 'flags slots over the per-spell cap as over_limit, not unwanted' do
      cache = [stacker('a', [['Heal', 90]]), stacker('b', [['Heal', 60]])]
      plan = script.compute_prune_plan(cache, keep_list: [], discard_list: [], max_per_spell: 100)
      expect(plan[:over_limit].map { |s| s[:spell] }.uniq).to eq(['Heal'])
      expect(plan[:over_limit].first[:total]).to eq(150)
      expect(plan[:unwanted]).to be_empty
    end

    it 'does not flag a spell sitting exactly at the cap (boundary)' do
      cache = [stacker('a', [['Heal', 100]])]
      plan = script.compute_prune_plan(cache, keep_list: [], discard_list: [], max_per_spell: 100)
      expect(plan[:over_limit]).to be_empty
      expect(plan[:keep].map { |s| s[:spell] }).to eq(['Heal'])
    end
  end

  # ===========================================================================
  # summarize_prune_plan -- headline math, incl. the B5 kept-portion fix
  # ===========================================================================
  describe '#summarize_prune_plan' do
    it 'counts the retained portion of over-limit spells in the KEEP total (B5)' do
      plan = { unwanted: [], keep: [],
               over_limit: [{ spell: 'Heal', count: 150, total: 150 }] }
      summary = script.summarize_prune_plan(plan, max_per_spell: 100)
      expect(summary[:keep_count]).to eq(100)
      expect(summary[:over_limit_total]).to eq(50)
      expect(summary[:remove_total]).to eq(50)
    end

    it 'sums unwanted removals and slots freed' do
      plan = { unwanted: [{ spell: 'Fire', count: 3 }, { spell: 'Ice', count: 2 }],
               over_limit: [], keep: [{ spell: 'Heal', count: 10 }] }
      summary = script.summarize_prune_plan(plan, max_per_spell: nil)
      expect(summary[:unwanted_total]).to eq(5)
      expect(summary[:slots_freed]).to eq(2)
      expect(summary[:keep_count]).to eq(10)
    end

    it 'counts distinct kept spell types across keep and over-limit groups' do
      plan = { unwanted: [],
               keep: [{ spell: 'Heal', count: 1 }, { spell: 'Heal', count: 2 }],
               over_limit: [{ spell: 'Fire', count: 200, total: 200 }] }
      summary = script.summarize_prune_plan(plan, max_per_spell: 100)
      expect(summary[:keep_spell_types]).to eq(2)
    end
  end

  # ===========================================================================
  # compute_consolidation_plan -- packing math
  # ===========================================================================
  describe '#compute_consolidation_plan' do
    it 'returns an empty plan for a nil cache' do
      plan = script.compute_consolidation_plan(nil)
      expect(plan[:moves]).to eq([])
      expect(plan[:overflow]).to be(false)
    end

    it 'generates a move for a spell split across two stackers' do
      cache = [stacker('a', [['S1', 1], []]), stacker('b', [['S1', 2]])]
      plan = script.compute_consolidation_plan(cache)
      expect(plan[:total_spells]).to eq(1)
      expect(plan[:total_scrolls]).to eq(3)
      expect(plan[:moves].size).to eq(1)
      move = plan[:moves].first
      expect(move[:spell]).to eq('S1')
      expect(move[:source_stacker_name]).to eq('b')
      expect(move[:target_stacker_name]).to eq('a')
    end

    it 'produces no moves when scrolls are already optimally packed' do
      cache = [stacker('a', [['S1', 1], ['S2', 1]]), stacker('b', [[], []])]
      plan = script.compute_consolidation_plan(cache)
      expect(plan[:moves]).to be_empty
    end

    it 'rolls onto the next stacker once the current one is full to capacity' do
      # Stacker a has capacity 1 (one slot); two distinct spells must split a/b.
      cache = [stacker('a', [['S1', 1]]), stacker('b', [['S2', 1]])]
      plan = script.compute_consolidation_plan(cache)
      expect(plan[:stackers_needed]).to eq(2)
      expect(plan[:overflow]).to be(false)
    end
  end

  # ===========================================================================
  # Cache readers (each_slot / normalize_stacker_data / totals) -- via UserVars
  # ===========================================================================
  describe '#normalize_stacker_data' do
    it 'flattens occupied slots to sorted [spell, count, stacker, page] rows' do
      allow(UserVars).to receive(:stackers).and_return(
        [stacker('folio', [['Heal', 5], [], ['Aegis', 2]])]
      )
      rows = script.normalize_stacker_data
      expect(rows).to eq([['Aegis', 2, 'folio', 3], ['Heal', 5, 'folio', 1]])
    end

    it 'rejects blank-named slots and is nil-safe' do
      allow(UserVars).to receive(:stackers).and_return([stacker('f', [['', 4], ['Heal', 1]])])
      expect(script.normalize_stacker_data.map(&:first)).to eq(['Heal'])
      allow(UserVars).to receive(:stackers).and_return(nil)
      expect(script.normalize_stacker_data).to eq([])
    end
  end

  describe '#totals_by_spell and #find_multi_slot_scrolls' do
    before do
      allow(UserVars).to receive(:stackers).and_return(
        [stacker('a', [['Heal', 5], ['Fire', 1]]), stacker('b', [['Heal', 3]])]
      )
    end

    it 'sums copies per spell across the cache' do
      expect(script.totals_by_spell).to eq('Heal' => 8, 'Fire' => 1)
    end

    it 'reports only spells with more than one total copy, most first' do
      expect(script.find_multi_slot_scrolls).to eq([['Heal', 8]])
    end
  end

  describe '#find_stacker_with_spell and #find_stacker_with_empty_slot' do
    it 'finds the stacker holding a spell, or nil' do
      allow(UserVars).to receive(:stackers).and_return(
        [stacker('a', [['Fire', 1]]), stacker('b', [['Heal', 1]])]
      )
      expect(script.find_stacker_with_spell('Heal')['name']).to eq('b')
      expect(script.find_stacker_with_spell('Missing')).to be_nil
    end

    it 'finds a stacker with an empty slot, nil-safe against nil contents (B1)' do
      allow(UserVars).to receive(:stackers).and_return(
        [{ 'name' => 'a', 'contents' => nil }, stacker('b', [['Fire', 1], []])]
      )
      expect(script.find_stacker_with_empty_slot['name']).to eq('b')
    end

    it 'returns nil for an empty-slot search when everything is full' do
      allow(UserVars).to receive(:stackers).and_return([stacker('a', [['Fire', 1]])])
      expect(script.find_stacker_with_empty_slot).to be_nil
    end
  end

  # ===========================================================================
  # abbrev_map / spell_abbrev / spell_data -- the isolated spell-data I/O seam
  # ===========================================================================
  describe '#abbrev_map' do
    it 'maps each occupied spell to its abbreviation, deduped and nil-safe' do
      allow(script).to receive(:spell_abbrev).with('Fire').and_return('fb')
      allow(script).to receive(:spell_abbrev).with('Heal').and_return('he')
      cache = [stacker('a', [['Fire', 1], []]), stacker('b', [['Heal', 1], ['Fire', 2]])]
      expect(script.abbrev_map(cache)).to eq('Fire' => 'fb', 'Heal' => 'he')
    end

    it 'returns an empty map for a nil cache' do
      expect(script.abbrev_map(nil)).to eq({})
    end
  end

  describe '#spell_abbrev' do
    it 'returns the abbreviation from spell data' do
      allow(script).to receive(:get_data).with('spells')
                                         .and_return(double(spell_data: { 'Heal' => { 'abbrev' => 'he' } }))
      expect(script.spell_abbrev('Heal')).to eq('he')
    end

    it 'returns nil when the spell is unknown' do
      allow(script).to receive(:get_data).with('spells').and_return(double(spell_data: {}))
      expect(script.spell_abbrev('Nope')).to be_nil
    end

    it 'returns nil (no crash) when spell data cannot be loaded' do
      allow(script).to receive(:get_data).and_raise(StandardError)
      expect(script.spell_abbrev('Heal')).to be_nil
    end
  end
end
