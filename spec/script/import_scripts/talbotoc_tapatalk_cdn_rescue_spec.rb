# frozen_string_literal: true

require "tmpdir"
require_relative "../../../script/import_scripts/talbotoc_tapatalk_cdn_rescue"

RSpec.describe TalbotocTapatalkCdnRescue do
  let(:report_dir) { Dir.mktmpdir("talbotoc-tapatalk-cdn-rescue") }
  let(:rescue_script) { described_class.new(report_dir: report_dir, dry_run: true, db_path: nil) }
  let(:image_url) do
    "https://uploads.tapatalk-cdn.com/20250505/174af8b9be5675edc16f739f2ce2d28b.jpg"
  end

  after { FileUtils.rm_rf(report_dir) }

  it "extracts Tapatalk CDN URLs without swallowing BBCode closing tags" do
    raw = "Before [img]#{image_url}[/img] after"

    expect(rescue_script.send(:tapatalk_urls, raw)).to contain_exactly(image_url)
  end

  it "ignores Tapatalk smiley URLs" do
    smiley_url = "https://groups.tapatalk-cdn.com/smilies/2174/1534583942.4584-smiley.gif"

    expect(rescue_script.send(:tapatalk_urls, "Before #{smiley_url} after")).to eq([])
  end

  it "replaces BBCode image URLs in place" do
    raw = "Before [img]#{image_url}[/img] after"

    repaired = rescue_script.send(:replace_url_in_place, raw, image_url, "![image](upload://abc)")

    expect(repaired).to eq("Before ![image](upload://abc) after")
  end

  it "replaces Markdown image URLs in place" do
    raw = "Before ![paint](#{image_url}) after"

    repaired = rescue_script.send(:replace_url_in_place, raw, image_url, "![image](upload://abc)")

    expect(repaired).to eq("Before ![image](upload://abc) after")
  end

  it "replaces HTML image URLs in place" do
    raw = %(Before <img src="#{image_url}" alt="paint"> after)

    repaired = rescue_script.send(:replace_url_in_place, raw, image_url, "![image](upload://abc)")

    expect(repaired).to eq("Before ![image](upload://abc) after")
  end

  it "classifies 404 responses as unavailable" do
    response = Net::HTTPNotFound.new("1.1", "404", "Not Found")
    response.instance_variable_set(:@read, true)
    response.body = "<html>missing</html>"

    result = rescue_script.send(:classify_download, image_url, { response: response }, 1)

    expect(result[:status]).to eq("unavailable_404")
  end

  it "classifies 429 responses as rate limited" do
    response = Net::HTTPTooManyRequests.new("1.1", "429", "Too Many Requests")
    response.instance_variable_set(:@read, true)
    response.body = "slow down"

    result = rescue_script.send(:classify_download, image_url, { response: response }, 2)

    expect(result[:status]).to eq("rate_limited")
    expect(result[:attempts]).to eq(2)
  end
end
