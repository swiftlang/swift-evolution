<!--
This file renders the contents of proposals.xml as a nicely-formatted HTML page.
The proposal data and this template are loaded using JavaScript (see index.html
on the gh-pages branch).
-->
<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
  <xsl:output method="html"/>

  <!-- The main template, which renders the page body. -->
  <xsl:template match="/proposals">
    <html>
      <head>
        <title>Swift-Evolution Proposal Status</title>
        <meta name="viewport" content="width=device-width, initial-scale=1"/>
        <xsl:call-template name="css"/>
      </head>
      <body>
        <!-- "GitHub Corners" by Tim Holman: https://github.com/tholman/github-corners -->
        <a href="https://github.com/apple/swift-evolution" title="Fork me on GitHub" class="github-corner"><svg xmlns="http://www.w3.org/2000/svg" version="1.1" alt="Fork me on GitHub" width="80" height="80" viewBox="0 0 250 250" style="fill:#ddd;color:#fff;position:absolute;top:0;right:0;border:0;"><path d="M0,0 L115,115 L130,115 L142,142 L250,250 L250,0 Z"></path><path d="M128.3,109.0 C113.8,99.7 119.0,89.6 119.0,89.6 C122.0,82.7 120.5,78.6 120.5,78.6 C119.2,72.0 123.4,76.3 123.4,76.3 C127.3,80.9 125.5,87.3 125.5,87.3 C122.9,97.6 130.6,101.9 134.4,103.2" fill="currentColor" style="transform-origin: 130px 106px;" class="octo-arm"></path><path d="M115.0,115.0 C114.9,115.1 118.7,116.5 119.8,115.4 L133.7,101.6 C136.9,99.2 139.9,98.4 142.2,98.6 C133.8,88.0 127.5,74.4 143.8,58.0 C148.5,53.4 154.0,51.2 159.7,51.0 C160.3,49.4 163.2,43.6 171.4,40.1 C171.4,40.1 176.1,42.5 178.8,56.2 C183.1,58.6 187.2,61.8 190.9,65.4 C194.5,69.0 197.7,73.2 200.1,77.6 C213.8,80.2 216.3,84.9 216.3,84.9 C212.7,93.1 206.9,96.0 205.4,96.6 C205.1,102.4 203.0,107.8 198.3,112.5 C181.9,128.9 168.3,122.5 157.7,114.1 C157.9,116.9 156.7,120.9 152.7,124.9 L141.0,136.5 C139.8,137.7 141.6,141.9 141.8,141.8 Z" fill="currentColor" class="octo-body"></path></svg></a>
        
        <h1>Swift Programming Language Evolution: Proposal Status</h1>
      
        <p>The <a href="https://github.com/apple/swift-evolution/blob/master/process.md">Swift evolution process</a> describes the process by which Swift evolves. This page tracks the currently active proposals in that process.</p>
      
        <xsl:call-template name="section">
          <xsl:with-param name="title">Active reviews</xsl:with-param>
          <xsl:with-param name="proposals" select="proposal[@status='active']"/>
        </xsl:call-template>
      
        <xsl:call-template name="section">
          <xsl:with-param name="title">Upcoming reviews</xsl:with-param>
          <xsl:with-param name="proposals" select="proposal[@status='scheduled']"/>
        </xsl:call-template>
      
        <xsl:call-template name="section">
          <xsl:with-param name="title">Proposals awaiting scheduling</xsl:with-param>
          <xsl:with-param name="proposals" select="proposal[@status='awaiting']"/>
        </xsl:call-template>
      
        <xsl:call-template name="section">
          <xsl:with-param name="title">Accepted (awaiting implementation)</xsl:with-param>
          <xsl:with-param name="description">This is the list of proposals which have been accepted for inclusion into Swift, but they are not implemented yet, and may not have anyone signed up to implement them. If they are not implemented in time for Swift 3, they will roll into a subsequent release.</xsl:with-param>
          <xsl:with-param name="proposals" select="proposal[@status='accepted']"/>
        </xsl:call-template>
      
        <xsl:call-template name="section">
          <xsl:with-param name="title">Implemented for Swift 3</xsl:with-param>
          <xsl:with-param name="proposals" select="proposal[@status='implemented'][@swift-version = 3]"/>
        </xsl:call-template>
      
        <xsl:call-template name="section">
          <xsl:with-param name="title">Implemented for Swift 2.2</xsl:with-param>
          <xsl:with-param name="proposals" select="proposal[@status='implemented'][@swift-version = 2.2]"/>
        </xsl:call-template>
      
        <xsl:call-template name="section">
          <xsl:with-param name="title">Deferred for future discussion</xsl:with-param>
          <xsl:with-param name="proposals" select="proposal[@status='deferred']"/>
        </xsl:call-template>
      
        <xsl:call-template name="section">
          <xsl:with-param name="title">Returned for revision</xsl:with-param>
          <xsl:with-param name="proposals" select="proposal[@status='returned']"/>
        </xsl:call-template>
      
        <xsl:call-template name="section">
          <xsl:with-param name="title">Rejected or withdrawn</xsl:with-param>
          <xsl:with-param name="proposals" select="proposal[@status='rejected']"/>
        </xsl:call-template>
      </body>
    </html>
  </xsl:template>

  <!-- Renders a section header and a table of proposals. -->
  <xsl:template name="section">
    <xsl:param name="title"/>
    <xsl:param name="description"/>
    <xsl:param name="proposals"/>
    <section>
      <h2><xsl:value-of select="$title"/></h2>
      <xsl:if test="$description"><p><xsl:value-of select="$description"/></p></xsl:if>
      <xsl:choose>
        <xsl:when test="count($proposals) = 0">
          <p>(none)</p>
        </xsl:when>
        <xsl:otherwise>
          <table>
            <xsl:apply-templates select="$proposals">
              <xsl:sort select="@id" order="ascending"/>
            </xsl:apply-templates>
          </table>
        </xsl:otherwise>
      </xsl:choose>
    </section>
  </xsl:template>

  <!-- Renders a single proposal. -->
  <xsl:template match="proposal">
    <tr class="proposal">
      <td><a class="number status-{@status}" href="https://github.com/apple/swift-evolution/blob/master/proposals/{@filename}">SE-<xsl:value-of select="@id"/></a></td>
      <td>
        <a class="title" href="https://github.com/apple/swift-evolution/blob/master/proposals/{@filename}">
          <xsl:call-template name="format-proposal-name">
            <xsl:with-param name="name" select="@name"/>
          </xsl:call-template>
        </a>
      </td>
    </tr>
  </xsl:template>
  
  <!-- Converts inline `code` in a proposal name to <code></code> elements. -->
  <xsl:template name="format-proposal-name">
    <xsl:param name="name"/>
    <xsl:choose>
      <xsl:when test="contains($name, '`')">
        <xsl:variable name="before-open-tick" select="substring-before($name, '`')"/>
        <xsl:variable name="after-open-tick" select="substring-after($name, '`')"/>
        <xsl:variable name="between-ticks" select="substring-before($after-open-tick, '`')"/>
        <xsl:variable name="after-close-tick" select="substring-after($after-open-tick, '`')"/>
        
        <!-- Render up to and including the first occurrence of `code` -->
        <xsl:value-of select="$before-open-tick"/>
        <code><xsl:value-of select="$between-ticks"/></code>
        
        <!-- Recursively format the rest of the string  -->
        <xsl:call-template name="format-proposal-name">
          <xsl:with-param name="name" select="$after-close-tick"/>
        </xsl:call-template>
      </xsl:when>
      <xsl:otherwise>
        <xsl:value-of select="$name"/>
      </xsl:otherwise>
    </xsl:choose>
  </xsl:template>
  
  <xsl:template name="css">
    <style type="text/css">
      * {
        margin: 0;
        padding: 0;
      }
      body {
        font-family: -apple-system, BlinkMacSystemFont, HelveticaNeue, Helvetica, Arial, sans-serif;
        -webkit-text-size-adjust: none;
      }
      body > h1, body > p, section > table, section > p {
        margin-left: 1rem;
        margin-right: 1rem;
      }
      p {
        margin-top: 1em;
        margin-bottom: 1em;
        line-height: 1.5em;
      }
      code {
        font-family: "SFMono-Regular", Menlo, Consolas, monospace;
        font-size: 90%;
        padding: 0.2em 0.3em;
        background-color: #f7f7f7;
        border-radius: 3px;
      }
      h1 {
        padding-top: 0.6em;
        margin-bottom: 0.6em;
      }
      h2 {
        margin: 0.5em 0em 0em;
        padding: 0.3em 1rem 0.4em;
        position: -webkit-sticky;
        position: -moz-sticky;
        position: -ms-sticky;
        position: -o-sticky;
        position: sticky;
        top: 0px;
        background-color: #fff;
      }
      @supports (backdrop-filter: blur(10px)) or (-webkit-backdrop-filter: blur(10px)) {
        h2 {
          background-color: rgba(255, 255, 255, 0.5);
          backdrop-filter: blur(10px);
          -webkit-backdrop-filter: blur(10px);
        }
      }
      h2 + p {
        margin-top: 0;
      }
      a {
        color: #4078c0;
        text-decoration: none;
      }
      a:hover, a:visited:hover {
        text-decoration: underline;
      }
      .github-corner:hover .octo-arm {
        animation: octocat-wave 560ms ease-in-out;
      }
      @keyframes octocat-wave {
        0%, 100% { transform: rotate(0); }
        20%, 60% { transform: rotate(-25deg); }
        40%, 80% { transform: rotate(10deg); }
      }
      @media (max-width:500px) {
        .github-corner:hover .octo-arm { animation: none; }
        .github-corner .octo-arm { animation: octocat-wave 560ms ease-in-out; }
      }
      .proposal a.title {
        color: #666;
      }
      .proposal a.title:visited {
        color: #888;
      }
      .proposal a.title:hover, .proposal a.title:visited:hover {
        color: #222;
      }
      table {
        margin-bottom: 1rem;
        border-spacing: 0.5em;
      }
      table, tr, td {
        padding: 0;
      }
      .proposal {
        font-size: 1.1em;
      }
      .proposal td {
        vertical-align: top;
      }
      .number {
        text-align: center;
        border-radius: 5px;
        font-size: 0.7em;
        font-weight: bold;
        padding: 0.2em 0.5em;
        display: block;
        white-space: nowrap;
        color: #fff;
      }
      .proposal a.number {
        color: #fff;
        text-decoration: none;
      }
      a.number.status-implemented {
        background-color: #319021;
      }
      a.number.status-accepted {
        background-color: #5abc4e;
      }
      a.number.status-active {
        background-color: #297de4;
      }
      a.number.status-scheduled {
        background-color: #78b8fb;
      }
      a.number.status-awaiting, a.number.status-deferred {
        background-color: #dddddd;
        color: #000;
      }
      a.number.status-returned {
        background-color: #f1b6b7;
      }
      a.number.status-rejected {
        background-color: #de5b60;
      }
    </style>
  </xsl:template>

</xsl:stylesheet>
