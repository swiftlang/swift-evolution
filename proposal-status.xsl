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
        <xsl:call-template name="css"/>
      </head>
      <h1>Swift Programming Language Evolution: Proposal Status</h1>
      
      The <a href="https://github.com/apple/swift-evolution/blob/master/process.md">Swift evolution process</a> describes the process by which Swift evolves. This page tracks the currently active proposals in that process.
      
      <h2>Active reviews</h2>
      <xsl:call-template name="section">
        <xsl:with-param name="proposals" select="proposal[@status='active']"/>
      </xsl:call-template>
      
      <h2>Upcoming reviews</h2>
      <xsl:call-template name="section">
        <xsl:with-param name="proposals" select="proposal[@status='scheduled']"/>
      </xsl:call-template>
      
      <h2>Proposals awaiting scheduling</h2>
      <xsl:call-template name="section">
        <xsl:with-param name="proposals" select="proposal[@status='awaiting']"/>
      </xsl:call-template>
      
      <h2>Accepted (awaiting implementation)</h2>
      <p>This is the list of proposals which have been accepted for inclusion into Swift, but they are not implemented yet, and may not have anyone signed up to implement them. If they are not implemented in time for Swift 3, they will roll into a subsequent release.</p>
      <xsl:call-template name="section">
        <xsl:with-param name="proposals" select="proposal[@status='accepted']"/>
      </xsl:call-template>
      
      <h2>Implemented for Swift 3</h2>
      <xsl:call-template name="section">
        <xsl:with-param name="proposals" select="proposal[@status='implemented'][@swift-version = 3]"/>
      </xsl:call-template>
      
      <h2>Implemented for Swift 2.2</h2>
      <xsl:call-template name="section">
        <xsl:with-param name="proposals" select="proposal[@status='implemented'][@swift-version = 2.2]"/>
      </xsl:call-template>
      
      <h2>Deferred for future discussion</h2>
      <xsl:call-template name="section">
        <xsl:with-param name="proposals" select="proposal[@status='deferred']"/>
      </xsl:call-template>
      
      <h2>Rejected or withdrawn</h2>
      <xsl:call-template name="section">
        <xsl:with-param name="proposals" select="proposal[@status='rejected']"/>
      </xsl:call-template>
    </html>
  </xsl:template>

  <!-- Renders a section header and a table of proposals. -->
  <xsl:template name="section">
    <xsl:param name="proposals"/>
    <xsl:choose>
      <xsl:when test="count($proposals) = 0">
        (none)
      </xsl:when>
      <xsl:otherwise>
        <table class="section">
          <xsl:apply-templates select="$proposals">
            <xsl:sort select="@id" order="descending"/>
          </xsl:apply-templates>
        </table>
      </xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <!-- Renders a single proposal. -->
  <xsl:template match="proposal">
    <tr class="proposal">
      <td class="number status-{@status}">SE-<xsl:value-of select="@id"/></td>
      <td><a href="https://github.com/apple/swift-evolution/blob/master/proposals/{@filename}"><xsl:value-of select="@name"/></a></td>
    </tr>
  </xsl:template>
  
  <xsl:template name="css">
    <style type="text/css">
      body {
        margin: 1em;
        font-family: -apple-system, BlinkMacSystemFont, HelveticaNeue, Helvetica, Arial, sans-serif;
      }
      a {
        color: #4078c0;
        text-decoration: none;
      }
      a:hover, a:visited:hover {
        text-decoration: underline;
      }
      .proposal a {
        color: #666;
      }
      .proposal a:visited {
        color: #999;
      }
      .proposal a:hover, .proposal a:visited:hover {
        color: #222;
      }
      table, tr, td {
        padding: 0;
      }
      .section {
        border-spacing: 0.5em;
      }
      .proposal {
        font-size: 1.1em;
      }
      .number {
        text-align: center;
        border-radius: 5px;
        font-size: 0.7em;
        font-weight: bold;
        padding: 0em 0.5em;
        vertical-align: middle;
        color: #fff;
      }
      .status-implemented {
        background-color: #319021;
      }
      .status-accepted {
        background-color: #5abc4e;
      }
      .status-active {
        background-color: #297de4;
      }
      .status-scheduled {
        background-color: #78b8fb;
      }
      .status-awaiting, .status-deferred {
        background-color: #dddddd;
        color: #000;
      }
      .status-returned {
        background-color: #f1b6b7;
      }
      .status-rejected {
        background-color: #de5b60;
      }
    </style>
  </xsl:template>

</xsl:stylesheet>
