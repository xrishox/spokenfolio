import Foundation
import EPUBKit

@testable import AudiobookKit

/// Builds small synthetic EPUBs in memory for parser and extraction tests.
/// Shapes mirror the two real reference books: Three-Body (EPUB 3, linear
/// footnote files, noterefs) and Mistborn (EPUB 3, titles only in the TOC).
struct EPUBFixture {
  struct Document {
    let id: String
    let path: String
    let xhtml: String
    var linear: Bool = true
  }

  var opfPath = "OEBPS/content.opf"
  var version = "3.0"
  var title = "Fixture Book"
  var author: String? = "Fixture Author"
  var language: String? = "en"
  var documents: [Document] = []
  var navXHTML: String?
  var navPath = "OEBPS/nav.xhtml"
  var ncxXML: String?
  var ncxPath = "OEBPS/toc.ncx"
  var guideXML = ""
  var extraMetadataXML = ""
  var coverImage: (path: String, data: Data)?
  var mimetype: String? = "application/epub+zip"

  func write() throws -> URL {
    var zip = ZIPFixtureWriter()
    if let mimetype {
      zip.addEntry(path: "mimetype", data: Data(mimetype.utf8), compress: false)
    }
    zip.addEntry(path: "META-INF/container.xml", data: Data(containerXML.utf8), compress: true)
    zip.addEntry(path: opfPath, data: Data(opfXML.utf8), compress: true)
    if let navXHTML {
      zip.addEntry(path: navPath, data: Data(navXHTML.utf8), compress: true)
    }
    if let ncxXML {
      zip.addEntry(path: ncxPath, data: Data(ncxXML.utf8), compress: true)
    }
    if let coverImage {
      zip.addEntry(path: coverImage.path, data: coverImage.data, compress: false)
    }
    for document in documents {
      zip.addEntry(path: document.path, data: Data(document.xhtml.utf8), compress: true)
    }
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("epub-fixture-\(UUID().uuidString).epub")
    try zip.finish().write(to: url)
    return url
  }

  private var containerXML: String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
      <rootfiles>
        <rootfile full-path="\(opfPath)" media-type="application/oebps-package+xml"/>
      </rootfiles>
    </container>
    """
  }

  private var opfXML: String {
    let opfDirectory = opfPath.contains("/")
      ? String(opfPath[..<opfPath.lastIndex(of: "/")!]) + "/" : ""
    func relative(_ path: String) -> String {
      path.hasPrefix(opfDirectory) ? String(path.dropFirst(opfDirectory.count)) : "../" + path
    }

    var manifest = ""
    if navXHTML != nil {
      manifest += """
        <item id="nav" href="\(relative(navPath))" media-type="application/xhtml+xml" properties="nav"/>\n
        """
    }
    if ncxXML != nil {
      manifest += """
        <item id="ncx" href="\(relative(ncxPath))" media-type="application/x-dtbncx+xml"/>\n
        """
    }
    if let coverImage {
      let mediaType = coverImage.data.starts(with: [0x89]) ? "image/png" : "image/jpeg"
      manifest += """
        <item id="cover-image" href="\(relative(coverImage.path))" media-type="\(mediaType)" properties="cover-image"/>\n
        """
    }
    for document in documents {
      manifest += """
        <item id="\(document.id)" href="\(relative(document.path))" media-type="application/xhtml+xml"/>\n
        """
    }

    var spine = ""
    for document in documents {
      let linear = document.linear ? "" : " linear=\"no\""
      spine += "<itemref idref=\"\(document.id)\"\(linear)/>\n"
    }

    let creator = author.map { "<dc:creator>\($0)</dc:creator>" } ?? ""
    let lang = language.map { "<dc:language>\($0)</dc:language>" } ?? ""
    let ncxAttribute = ncxXML != nil ? " toc=\"ncx\"" : ""
    return """
      <?xml version="1.0" encoding="UTF-8"?>
      <package xmlns="http://www.idpf.org/2007/opf" version="\(version)" unique-identifier="uid">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
          <dc:identifier id="uid">fixture-\(title)</dc:identifier>
          <dc:title>\(title)</dc:title>
          \(creator)
          \(lang)
          \(extraMetadataXML)
        </metadata>
        <manifest>
          \(manifest)
        </manifest>
        <spine\(ncxAttribute)>
          \(spine)
        </spine>
        \(guideXML)
      </package>
      """
  }

  // MARK: - Content helpers

  static func xhtml(body: String, head: String = "") -> String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
      <head><title>Fixture</title>\(head)</head>
      <body>\(body)</body>
    </html>
    """
  }

  static func nav(tocItems: String, landmarks: String = "") -> String {
    let landmarksNav =
      landmarks.isEmpty
      ? ""
      : """
        <nav epub:type="landmarks"><ol>\(landmarks)</ol></nav>
        """
    return xhtml(
      body: """
        <nav epub:type="toc"><ol>\(tocItems)</ol></nav>
        \(landmarksNav)
        """)
  }

  /// Minimal 1×1 PNG.
  static var pngPixel: Data {
    Data(base64Encoded:
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
    )!
  }

  // MARK: - Reference shapes

  /// Three-Body shape: chapters with inline noterefs; footnote files are
  /// linear spine members containing only footnote asides; landmarks mark
  /// bodymatter; front matter includes title/copyright/contents pages.
  static func threeBodyShape() -> EPUBFixture {
    var fixture = EPUBFixture()
    fixture.title = "Three Body Fixture"
    fixture.documents = [
      Document(
        id: "titlepage", path: "OEBPS/titlepage.xhtml",
        xhtml: xhtml(body: "<p>Three Body Fixture</p><p>Fixture Author</p>")),
      Document(
        id: "copyright", path: "OEBPS/copyright.xhtml",
        xhtml: xhtml(body: "<p>Copyright 2024. All rights reserved.</p>")),
      Document(
        id: "contents", path: "OEBPS/contents.xhtml",
        xhtml: xhtml(body: "<p>Contents</p><p>Chapter 1</p><p>Chapter 2</p>")),
      Document(
        id: "part1", path: "OEBPS/part1.xhtml",
        xhtml: xhtml(body: "<p class=\"part\">PART I</p><p class=\"part\">SILENT SPRING</p>")),
      Document(
        id: "ch1", path: "OEBPS/ch1.xhtml",
        xhtml: xhtml(
          body: """
            <p class="num">1</p>
            <p class="title">The Madness Years</p>
            <p class="setting">China, 1967</p>
            <p>The Red Union had been attacking the headquarters
            <span id="a1"/><a href="fn1.xhtml" epub:type="noteref" class="noteref">1</a>
            for two days.</p>
            <p>Their flags fluttered restlessly around the brigade
            <span id="a2"/><a href="fn2.xhtml" epub:type="noteref" class="noteref">2</a>
            like kindling.</p>
            """)),
      Document(
        id: "ch2", path: "OEBPS/ch2.xhtml",
        xhtml: xhtml(
          body: """
            <p class="num">2</p>
            <p class="title">Silent Spring</p>
            <p>Two years later, the Greater Khingan Mountains.</p>
            <p>See the <a href="https://example.com/map">official map</a> for the region.</p>
            """)),
      Document(
        id: "fn1", path: "OEBPS/fn1.xhtml",
        xhtml: xhtml(
          body: """
            <aside epub:type="footnote"><p><a href="ch1.xhtml#a1">1</a>
            Translator's Note: This refers to the events of 1967.</p></aside>
            """)),
      Document(
        id: "fn2", path: "OEBPS/fn2.xhtml",
        xhtml: xhtml(
          body: """
            <aside epub:type="footnote"><p><a href="ch1.xhtml#a2">2</a>
            Translator's Note: A cultural reference.</p></aside>
            """)),
      Document(
        id: "aboutauthor", path: "OEBPS/aboutauthor.xhtml",
        xhtml: xhtml(body: "<p>About the Author</p><p>Fixture Author writes fixtures.</p>")),
    ]
    fixture.navXHTML = nav(
      tocItems: """
        <li><a href="titlepage.xhtml">Title Page</a></li>
        <li><a href="copyright.xhtml">Copyright</a></li>
        <li><a href="contents.xhtml">Contents</a></li>
        <li><a href="part1.xhtml">Part I: Silent Spring</a>
          <ol>
            <li><a href="ch1.xhtml">1. The Madness Years</a></li>
            <li><a href="ch2.xhtml">2. Silent Spring</a></li>
          </ol>
        </li>
        <li><a href="aboutauthor.xhtml">About the Author</a></li>
        """,
      landmarks: """
        <li><a epub:type="cover" href="titlepage.xhtml">Cover</a></li>
        <li><a epub:type="toc" href="contents.xhtml">Table of Contents</a></li>
        <li><a epub:type="bodymatter" href="part1.xhtml">Begin Reading</a></li>
        """)
    fixture.coverImage = ("OEBPS/cover.png", pngPixel)
    return fixture
  }

  /// Mistborn shape: chapter titles exist only in the TOC; chapter bodies
  /// open with a bare number heading; part separators are near-empty files.
  static func mistbornShape() -> EPUBFixture {
    var fixture = EPUBFixture()
    fixture.title = "Mistborn Fixture"
    fixture.documents = [
      Document(
        id: "title", path: "OEBPS/title.xhtml",
        xhtml: xhtml(body: "<p>Mistborn Fixture</p>")),
      Document(
        id: "dedication", path: "OEBPS/dedication.xhtml",
        xhtml: xhtml(body: "<p>For the reader who kept listening.</p>")),
      Document(
        id: "prologue", path: "OEBPS/prologue.xhtml",
        xhtml: xhtml(
          body: """
            <h2 id="pr">Prologue</h2>
            <p>Ash fell from the sky.</p>
            <hr class="scene"/>
            <p><span id="page_12"/>The mists came every night.</p>
            """)),
      Document(
        id: "part1", path: "OEBPS/part1.xhtml",
        xhtml: xhtml(body: "<p>PART ONE</p><p>THE SURVIVOR OF HATHSIN</p>")),
      Document(
        id: "ch1", path: "OEBPS/ch1.xhtml",
        xhtml: xhtml(
          body: """
            <h2 id="c1"><a href="../OEBPS/nav.xhtml#toc">1</a></h2>
            <p>Vin watched the crew from the shadows.</p>
            <p><img src="images/symbol.jpg" alt=""/></p>
            <p>She had learned to expect betrayal.</p>
            """)),
      Document(
        id: "ch2", path: "OEBPS/ch2.xhtml",
        xhtml: xhtml(
          body: """
            <h2 id="c2"><a href="../OEBPS/nav.xhtml#toc">2</a></h2>
            <p>Kelsier smiled and surveyed the room.</p>
            """)),
    ]
    fixture.navXHTML = nav(
      tocItems: """
        <li><a href="title.xhtml">Title Page</a></li>
        <li><a href="dedication.xhtml">Dedication</a></li>
        <li><a href="prologue.xhtml#pr">Prologue</a></li>
        <li><a href="part1.xhtml">Part One: The Survivor of Hathsin</a>
          <ol>
            <li><a href="ch1.xhtml#c1">Chapter 1</a></li>
            <li><a href="ch2.xhtml#c2">Chapter 2</a></li>
          </ol>
        </li>
        """,
      landmarks: """
        <li><a epub:type="bodymatter" href="prologue.xhtml">Begin Reading</a></li>
        """)
    return fixture
  }

  /// EPUB 2 shape: NCX + guide, no nav document, cover via meta name=cover.
  static func epub2Shape() -> EPUBFixture {
    var fixture = EPUBFixture()
    fixture.version = "2.0"
    fixture.title = "Legacy Fixture"
    fixture.documents = [
      Document(
        id: "cover-page", path: "OEBPS/cover.xhtml",
        xhtml: xhtml(body: "<p>Legacy Fixture</p>")),
      Document(
        id: "ch1", path: "OEBPS/text/ch1.xhtml",
        xhtml: xhtml(
          body: """
            <h1>Chapter One</h1>
            <p>An old-fashioned opening<sup><a href="notes.xhtml#n1">1</a></sup> line.</p>
            """)),
      Document(
        id: "ch2", path: "OEBPS/text/ch2.xhtml",
        xhtml: xhtml(body: "<h1>Chapter Two</h1><p>A second chapter.</p>")),
      Document(
        id: "notes", path: "OEBPS/text/notes.xhtml",
        xhtml: xhtml(
          body: """
            <div class="footnote" id="n1"><p>1. A note. <a href="ch1.xhtml">↩</a></p></div>
            """)),
    ]
    fixture.ncxXML = """
      <?xml version="1.0" encoding="UTF-8"?>
      <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
        <navMap>
          <navPoint id="p1" playOrder="1"><navLabel><text>Cover</text></navLabel>
            <content src="cover.xhtml"/></navPoint>
          <navPoint id="p2" playOrder="2"><navLabel><text>Chapter One</text></navLabel>
            <content src="text/ch1.xhtml"/>
            <navPoint id="p2a" playOrder="3"><navLabel><text>A Section</text></navLabel>
              <content src="text/ch1.xhtml#s1"/></navPoint>
          </navPoint>
          <navPoint id="p3" playOrder="4"><navLabel><text>Chapter Two</text></navLabel>
            <content src="text/ch2.xhtml"/></navPoint>
          <navPoint id="p4" playOrder="5"><navLabel><text>Notes</text></navLabel>
            <content src="text/notes.xhtml"/></navPoint>
        </navMap>
      </ncx>
      """
    fixture.guideXML = """
      <guide>
        <reference type="cover" title="Cover" href="cover.xhtml"/>
        <reference type="text" title="Begin" href="text/ch1.xhtml"/>
        <reference type="notes" title="Notes" href="text/notes.xhtml"/>
      </guide>
      """
    fixture.coverImage = ("OEBPS/images/cover.png", pngPixel)
    fixture.extraMetadataXML = "<meta name=\"cover\" content=\"cover-image\"/>"
    return fixture
  }

  /// No TOC at all: spine order is the only structure.
  static func spineOnlyShape() -> EPUBFixture {
    var fixture = EPUBFixture()
    fixture.title = "Bare Fixture"
    fixture.documents = [
      Document(
        id: "one", path: "OEBPS/one.xhtml",
        xhtml: xhtml(body: "<h1>First Part</h1><p>First body.</p>")),
      Document(
        id: "two", path: "OEBPS/two.xhtml",
        xhtml: xhtml(body: "<p>Second body with no heading.</p>")),
    ]
    return fixture
  }
}
