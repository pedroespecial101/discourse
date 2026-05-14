# frozen_string_literal: true

require "tmpdir"
require_relative "../../../script/import_scripts/talbotoc_smiley_repair"

RSpec.describe TalbotocSmileyRepair do
  let(:report_dir) { Dir.mktmpdir("talbotoc-smiley-repair") }
  let(:repair) { described_class.new(report_dir: report_dir, dry_run: true) }
  let(:smiley_url) do
    "https://groups.tapatalk-cdn.com/smilies/2174/1534583942.4584-smiley.gif"
  end

  before do
    repair.instance_variable_set(
      :@smiley_map,
      { "1534583942.4584-smiley.gif" => { emoji_name: "talbotoc_smiley_001", status: "dry_run" } },
    )
  end

  after { FileUtils.rm_rf(report_dir) }

  def repair_raw(raw)
    stats = Hash.new(0)
    [repair.send(:repair_smileys, raw, stats), stats]
  end

  it "replaces bare Tapatalk smiley URLs in place" do
    raw = "That sounds painful #{smiley_url} but fixable"

    repaired, stats = repair_raw(raw)

    expect(repaired).to eq("That sounds painful :talbotoc_smiley_001: but fixable")
    expect(stats[:replacements]).to eq(1)
  end

  it "unwraps Tapatalk smiley BBCode without moving the smiley" do
    raw = "Before [img]#{smiley_url}[/img] after"

    repaired, stats = repair_raw(raw)

    expect(repaired).to eq("Before :talbotoc_smiley_001: after")
    expect(stats[:replacements]).to eq(1)
  end

  it "replaces Markdown image smileys in place" do
    raw = "Before ![smile](#{smiley_url}) after"

    repaired, stats = repair_raw(raw)

    expect(repaired).to eq("Before :talbotoc_smiley_001: after")
    expect(stats[:replacements]).to eq(1)
  end

  it "replaces HTML image smileys in place" do
    raw = %(Before <img src="#{smiley_url}" alt="smile"> after)

    repaired, stats = repair_raw(raw)

    expect(repaired).to eq("Before :talbotoc_smiley_001: after")
    expect(stats[:replacements]).to eq(1)
  end

  it "leaves unknown smileys untouched and records them" do
    raw = "Before https://groups.tapatalk-cdn.com/smilies/2174/unknown-smiley.gif after"

    repaired, stats = repair_raw(raw)

    expect(repaired).to eq(raw)
    expect(stats[:unresolved_smileys]).to eq(1)
    expect(stats[:unresolved_filenames]).to contain_exactly("unknown-smiley.gif")
  end

  it "derives stable custom emoji names from original filenames" do
    expect(repair.send(:emoji_name_for, "1534583942.4584-smiley.gif")).to eq(
      "talbotoc_smiley_1534583942_4584",
    )
  end
end
